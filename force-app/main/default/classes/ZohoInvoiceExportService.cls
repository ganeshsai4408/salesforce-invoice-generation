/**
 * Builds the Zoho invoice CSV from Zoho_Invoice_Column__mdt.
 *
 * Each active column record fills at most one of:
 *   Field_API_Name__c    - read from Object_API_Name__c: the invoice (Invoice_New__c) or any
 *                          child object of the invoice (e.g. Invoiced_Resource__c)
 *   Static_Value__c      - fixed text
 *   Calculation_Class__c - Apex class implementing ZohoColumnCalculation, created by name,
 *                          with Calculation_Inputs__c as its comma-separated inputs
 * and leaves all of them empty for a blank column.
 * Optional condition: when the invoice field Condition_Field__c matches one of the
 * comma-separated Condition_Value__c values ((blank) = empty), Alternate_Value__c is written instead.
 *
 * Objects and fields are resolved by API name from the schema, so new objects, fields,
 * conditions or values need no code change. One CSV row is written per record of the
 * child object used by the columns; invoice columns repeat on every row of the invoice.
 */
public with sharing class ZohoInvoiceExportService {

    private static final Schema.SObjectType INVOICE_TYPE = Invoice_New__c.SObjectType;
    private static final Integer MAX_PATH_DEPTH = 5;
    private static final String BLANK_TOKEN = '(blank)';

    // Lets tests run against a known column set instead of the deployed records
    @TestVisible
    private static List<Zoho_Invoice_Column__mdt> testColumns;

    private final List<Zoho_Invoice_Column__mdt> columns;

    // Resolved configuration, keyed by column DeveloperName
    private final Map<String, String> fieldPaths = new Map<String, String>();
    private final Set<String> lineColumns = new Set<String>();
    private final Map<String, String> conditionPaths = new Map<String, String>();
    private final Map<String, Set<String>> conditionValues = new Map<String, Set<String>>();
    private final Map<String, ZohoColumnCalculation> calculations = new Map<String, ZohoColumnCalculation>();
    private final Map<String, List<String>> calculationInputs = new Map<String, List<String>>();
    private final Set<String> calculationFields = new Set<String>();

    // Child relationship that drives one row per child record (null = one row per invoice)
    private String lineRelationshipName;

    public ZohoInvoiceExportService() {
        this.columns = loadColumns();
        validate();
    }

    public List<Zoho_Invoice_Column__mdt> getColumns() {
        return columns;
    }

    // ------------------------------------------------------------------
    // CSV
    // ------------------------------------------------------------------

    public String buildCsv(List<Id> invoiceIds) {
        List<String> lines = new List<String>{ toCsvLine(getHeaders()) };
        for (List<String> row : buildRows(invoiceIds)) {
            lines.add(toCsvLine(row));
        }
        return String.join(lines, '\r\n');
    }

    public List<String> getHeaders() {
        List<String> headers = new List<String>();
        for (Zoho_Invoice_Column__mdt c : columns) {
            headers.add(c.Header__c == null ? '' : c.Header__c);
        }
        return headers;
    }

    public List<List<String>> buildRows(List<Id> invoiceIds) {
        List<List<String>> rows = new List<List<String>>();
        if (invoiceIds == null || invoiceIds.isEmpty()) {
            return rows;
        }

        for (SObject invoice : queryInvoices(invoiceIds)) {
            List<String> invoiceCells = new List<String>();
            for (Zoho_Invoice_Column__mdt c : columns) {
                invoiceCells.add(lineColumns.contains(c.DeveloperName) ? '' : cellValue(c, invoice, invoice));
            }

            List<SObject> lines = lineRelationshipName == null ? null : invoice.getSObjects(lineRelationshipName);
            if (lines == null || lines.isEmpty()) {
                rows.add(invoiceCells);
                continue;
            }
            for (SObject line : lines) {
                List<String> cells = new List<String>();
                for (Integer i = 0; i < columns.size(); i++) {
                    Zoho_Invoice_Column__mdt c = columns[i];
                    cells.add(lineColumns.contains(c.DeveloperName) ? cellValue(c, line, invoice) : invoiceCells[i]);
                }
                rows.add(cells);
            }
        }
        return rows;
    }

    private String cellValue(Zoho_Invoice_Column__mdt c, SObject source, SObject invoice) {
        String value;
        if (conditionMatches(c, invoice)) {
            value = c.Alternate_Value__c;
        } else if (fieldPaths.containsKey(c.DeveloperName)) {
            value = formatValue(readPath(source, fieldPaths.get(c.DeveloperName)));
        } else if (String.isNotBlank(c.Static_Value__c)) {
            value = c.Static_Value__c;
        } else if (calculations.containsKey(c.DeveloperName)) {
            value = calculations.get(c.DeveloperName).calculate(invoice, calculationInputs.get(c.DeveloperName), c);
        }
        if (String.isBlank(value)) {
            return '';
        }
        return (c.Prefix__c == null ? '' : c.Prefix__c) + value;
    }

    private Boolean conditionMatches(Zoho_Invoice_Column__mdt c, SObject invoice) {
        String path = conditionPaths.get(c.DeveloperName);
        if (path == null) {
            return false;
        }
        String actual = formatValue(readPath(invoice, path)).trim().toLowerCase();
        return conditionValues.get(c.DeveloperName).contains(String.isBlank(actual) ? BLANK_TOKEN : actual);
    }

    // Dates in the format of custom label Zoho_Invoice_Export_Date_Format; numbers without trailing zeros
    @TestVisible
    private static String formatValue(Object raw) {
        if (raw == null) {
            return '';
        }
        if (raw instanceof Date) {
            return Datetime.newInstanceGmt((Date) raw, Time.newInstance(0, 0, 0, 0)).formatGmt(System.Label.Zoho_Invoice_Export_Date_Format);
        }
        if (raw instanceof Datetime) {
            return ((Datetime) raw).format(System.Label.Zoho_Invoice_Export_Date_Format);
        }
        if (raw instanceof Decimal) {
            return ((Decimal) raw).stripTrailingZeros().toPlainString();
        }
        return String.valueOf(raw);
    }

    // CSV-safe escaping
    @TestVisible
    private static String prepareCSVBody(String rowData) {
        if (rowData == null) {
            return '';
        }
        Boolean mustQuote = rowData.contains(',') || rowData.contains('"') || rowData.contains('\n') || rowData.contains('\r');
        rowData = rowData.replace('"', '""');
        return mustQuote ? '"' + rowData + '"' : rowData;
    }

    private static String toCsvLine(List<String> cells) {
        List<String> escaped = new List<String>();
        for (String cell : cells) {
            escaped.add(prepareCSVBody(cell));
        }
        return String.join(escaped, ',');
    }

    // ------------------------------------------------------------------
    // Query
    // ------------------------------------------------------------------

    private List<SObject> queryInvoices(List<Id> invoiceIds) {
        Set<String> invoiceFields = new Set<String>{ 'Id', 'Name' };
        invoiceFields.addAll(calculationFields);
        invoiceFields.addAll(conditionPaths.values());
        Set<String> lineFields = new Set<String>{ 'Id' };

        for (Zoho_Invoice_Column__mdt c : columns) {
            String path = fieldPaths.get(c.DeveloperName);
            if (path != null) {
                (lineColumns.contains(c.DeveloperName) ? lineFields : invoiceFields).add(path);
            }
        }

        String soql = 'SELECT ' + String.join(new List<String>(invoiceFields), ', ');
        if (lineRelationshipName != null) {
            soql += ', (SELECT ' + String.join(new List<String>(lineFields), ', ')
                + ' FROM ' + lineRelationshipName + ' ORDER BY CreatedDate, Id)';
        }
        soql += ' FROM ' + INVOICE_TYPE.getDescribe().getName() + ' WHERE Id IN :invoiceIds ORDER BY Name';

        // Field paths come only from admin-maintained custom metadata and are validated
        // against the schema. Sharing is enforced (with sharing); field access matches the
        // existing Download Zoho File button.
        return Database.queryWithBinds(soql, new Map<String, Object>{ 'invoiceIds' => invoiceIds }, AccessLevel.SYSTEM_MODE);
    }

    /** Reads a dotted field path (e.g. Account__r.Name) from a record; null if any part is empty. */
    public static Object readPath(SObject record, String path) {
        List<String> parts = path.split('\\.');
        SObject current = record;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            if (current == null) {
                return null;
            }
            current = current.getSObject(parts[i]);
        }
        return current == null ? null : current.get(parts[parts.size() - 1]);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    private static List<Zoho_Invoice_Column__mdt> loadColumns() {
        List<Zoho_Invoice_Column__mdt> source = testColumns != null ? testColumns : [
            SELECT DeveloperName, MasterLabel, Order__c, Header__c, Active__c, Object_API_Name__c, Field_API_Name__c,
                Static_Value__c, Calculation_Class__c, Calculation_Inputs__c,
                Condition_Field__c, Condition_Value__c, Alternate_Value__c, Prefix__c
            FROM Zoho_Invoice_Column__mdt
        ];

        // Sort by Order, then DeveloperName (CMDT queries have limited ORDER BY support)
        Map<String, Zoho_Invoice_Column__mdt> byKey = new Map<String, Zoho_Invoice_Column__mdt>();
        for (Zoho_Invoice_Column__mdt c : source) {
            if (c.Active__c) {
                Decimal order = c.Order__c == null ? 99999 : c.Order__c;
                byKey.put(String.valueOf(order.intValue() + 100000) + '|' + c.DeveloperName, c);
            }
        }
        List<String> keys = new List<String>(byKey.keySet());
        keys.sort();

        List<Zoho_Invoice_Column__mdt> sorted = new List<Zoho_Invoice_Column__mdt>();
        for (String key : keys) {
            sorted.add(byKey.get(key));
        }
        return sorted;
    }

    private void validate() {
        if (columns.isEmpty()) {
            throw new ZohoInvoiceExportException('No active Zoho Invoice Column records found. Ask your administrator to configure Custom Metadata "Zoho Invoice Column".');
        }

        List<String> errors = new List<String>();
        for (Zoho_Invoice_Column__mdt c : columns) {
            String name = 'Column ' + (c.Order__c == null ? '?' : String.valueOf(c.Order__c.intValue())) + ' "' + c.Header__c + '"';
            try {
                validateColumn(c, name);
            } catch (ZohoInvoiceExportException e) {
                errors.add(e.getMessage());
            }
        }
        if (!errors.isEmpty()) {
            throw new ZohoInvoiceExportException('Zoho Invoice Column configuration has errors:\n- ' + String.join(errors, '\n- '));
        }
    }

    private void validateColumn(Zoho_Invoice_Column__mdt c, String name) {
        Integer filled = (String.isNotBlank(c.Field_API_Name__c) ? 1 : 0)
            + (String.isNotBlank(c.Static_Value__c) ? 1 : 0)
            + (String.isNotBlank(c.Calculation_Class__c) ? 1 : 0);
        if (filled > 1) {
            throw new ZohoInvoiceExportException(name + ': fill only one of Field API Name, Fixed Text or Calculation Class.');
        }

        if (String.isNotBlank(c.Field_API_Name__c)) {
            Schema.SObjectType sourceType = resolveSourceObject(c, name);
            try {
                fieldPaths.put(c.DeveloperName, normalizePath(sourceType, c.Field_API_Name__c));
            } catch (ZohoInvoiceExportException e) {
                throw new ZohoInvoiceExportException(name + ': Field API Name ' + e.getMessage());
            }
        }

        if (String.isNotBlank(c.Calculation_Class__c)) {
            resolveCalculation(c, name);
        }

        if (String.isNotBlank(c.Condition_Field__c)) {
            Set<String> values = new Set<String>();
            for (String part : (c.Condition_Value__c == null ? '' : c.Condition_Value__c).split(',')) {
                if (String.isNotBlank(part)) {
                    values.add(part.trim().toLowerCase());
                }
            }
            if (values.isEmpty()) {
                throw new ZohoInvoiceExportException(name + ': Condition Value is required when Condition Field is filled.');
            }
            try {
                conditionPaths.put(c.DeveloperName, normalizePath(INVOICE_TYPE, c.Condition_Field__c));
            } catch (ZohoInvoiceExportException e) {
                throw new ZohoInvoiceExportException(name + ': Condition Field ' + e.getMessage());
            }
            conditionValues.put(c.DeveloperName, values);
        }
    }

    /** Creates the calculation class by name and validates the invoice fields it reads. */
    private void resolveCalculation(Zoho_Invoice_Column__mdt c, String name) {
        String className = c.Calculation_Class__c.trim();
        Type calculationType = Type.forName(className);
        Object instance;
        try {
            instance = calculationType == null ? null : calculationType.newInstance();
        } catch (Exception e) {
            instance = null;
        }
        if (!(instance instanceof ZohoColumnCalculation)) {
            throw new ZohoInvoiceExportException(name + ': Calculation Class "' + className + '" was not found or is not a Zoho column calculation.');
        }
        ZohoColumnCalculation calculation = (ZohoColumnCalculation) instance;

        List<String> inputs = new List<String>();
        for (String part : (c.Calculation_Inputs__c == null ? '' : c.Calculation_Inputs__c).split(',')) {
            if (String.isNotBlank(part)) {
                inputs.add(part.trim());
            }
        }

        Set<String> fields;
        try {
            fields = calculation.getInvoiceFields(inputs);
        } catch (ZohoInvoiceExportException e) {
            throw new ZohoInvoiceExportException(name + ': ' + className + ' ' + e.getMessage());
        }

        // Validate the field inputs and pass them on with canonical API names
        for (Integer i = 0; i < inputs.size(); i++) {
            if (fields.contains(inputs[i])) {
                String canonical;
                try {
                    canonical = normalizePath(INVOICE_TYPE, inputs[i]);
                } catch (ZohoInvoiceExportException e) {
                    throw new ZohoInvoiceExportException(name + ': Calculation Inputs ' + e.getMessage());
                }
                calculationFields.add(canonical);
                inputs[i] = canonical;
            }
        }
        calculations.put(c.DeveloperName, calculation);
        calculationInputs.put(c.DeveloperName, inputs);
    }

    /**
     * Object API Name must be the invoice or one of its child objects. A child object makes the
     * column line-level; all line-level columns must use the same child object.
     */
    private Schema.SObjectType resolveSourceObject(Zoho_Invoice_Column__mdt c, String name) {
        String objectName = c.Object_API_Name__c == null ? '' : c.Object_API_Name__c.trim();
        String invoiceName = INVOICE_TYPE.getDescribe().getName();
        if (String.isBlank(objectName)) {
            throw new ZohoInvoiceExportException(name + ': Object API Name is required when Field API Name is filled (e.g. ' + invoiceName + ').');
        }
        if (objectName.equalsIgnoreCase(invoiceName)) {
            return INVOICE_TYPE;
        }

        List<Schema.ChildRelationship> matches = new List<Schema.ChildRelationship>();
        for (Schema.ChildRelationship rel : INVOICE_TYPE.getDescribe().getChildRelationships()) {
            if (rel.getRelationshipName() != null && rel.getChildSObject().getDescribe().getName().equalsIgnoreCase(objectName)) {
                matches.add(rel);
            }
        }
        if (matches.isEmpty()) {
            throw new ZohoInvoiceExportException(name + ': Object API Name "' + objectName + '" must be ' + invoiceName
                + ' or a child object of it. For related records such as Account, use ' + invoiceName + ' with a path like Account__r.Name.');
        }
        if (matches.size() > 1) {
            throw new ZohoInvoiceExportException(name + ': ' + objectName + ' is linked to the invoice more than once, so the line items cannot be identified.');
        }

        String relationship = matches[0].getRelationshipName();
        if (lineRelationshipName != null && lineRelationshipName != relationship) {
            throw new ZohoInvoiceExportException(name + ': all line item columns must use the same Object API Name.');
        }
        lineRelationshipName = relationship;
        lineColumns.add(c.DeveloperName);
        return matches[0].getChildSObject();
    }

    /** Resolves a dotted path against the schema and returns it with canonical API names. */
    @TestVisible
    private static String normalizePath(Schema.SObjectType type, String path) {
        List<String> parts = path.trim().split('\\.');
        if (parts.size() > MAX_PATH_DEPTH + 1) {
            throw new ZohoInvoiceExportException('"' + path + '" goes deeper than ' + MAX_PATH_DEPTH + ' relationships.');
        }
        List<String> canonical = new List<String>();
        Schema.SObjectType current = type;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            Schema.DescribeFieldResult lookup = findRelationship(current, parts[i].trim());
            if (lookup == null) {
                throw new ZohoInvoiceExportException('"' + path + '": "' + parts[i] + '" is not a relationship on ' + current.getDescribe().getName() + '.');
            }
            canonical.add(lookup.getRelationshipName());
            current = lookup.getReferenceTo()[0];
        }
        Schema.SObjectField field = current.getDescribe().fields.getMap().get(parts[parts.size() - 1].trim().toLowerCase());
        if (field == null) {
            throw new ZohoInvoiceExportException('"' + path + '": field "' + parts[parts.size() - 1] + '" does not exist on ' + current.getDescribe().getName() + '.');
        }
        canonical.add(field.getDescribe().getName());
        return String.join(canonical, '.');
    }

    private static Schema.DescribeFieldResult findRelationship(Schema.SObjectType type, String relationshipName) {
        for (Schema.SObjectField field : type.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult d = field.getDescribe();
            if (d.getType() == Schema.DisplayType.REFERENCE && d.getRelationshipName() != null
                    && d.getRelationshipName().equalsIgnoreCase(relationshipName) && !d.getReferenceTo().isEmpty()) {
                return d;
            }
        }
        return null;
    }
}
