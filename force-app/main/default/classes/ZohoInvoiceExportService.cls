/**
 * Builds the Zoho invoice CSV from Zoho_Invoice_Column__mdt.
 *
 * Each active column record defines header, order and Value Source:
 *   Invoice Field           - Field_API_Name__c read from the invoice (Invoice_New__c)
 *   Invoice Line Item Field - Field_API_Name__c read from the invoiced PO line item (Invoiced_Resource__c)
 *   Fixed Text              - Static_Value__c
 *   Calculation             - ZohoInvoiceExportCalculations
 *   Blank                   - empty
 * When Use_Export_Value__c is ticked, Export invoices get Export_Value__c instead.
 * One CSV row is written per invoiced PO line item; invoice-level columns repeat on every
 * row of the invoice. An invoice without line items gives one row.
 */
public with sharing class ZohoInvoiceExportService {

    // Values of Zoho_Invoice_Column__mdt.Value_Source__c
    public static final String SOURCE_INVOICE_FIELD = 'Invoice Field';
    public static final String SOURCE_LINE_FIELD = 'Invoice Line Item Field';
    public static final String SOURCE_FIXED_TEXT = 'Fixed Text';
    public static final String SOURCE_CALCULATION = 'Calculation';
    public static final String SOURCE_BLANK = 'Blank';

    private static final String EXPORT_TYPE = 'Export';

    private static final String LINE_RELATIONSHIP = 'Invoiced_Resources__r';
    private static final Integer MAX_PATH_DEPTH = 5;

    // Lets tests run against a known column set instead of the deployed records
    @TestVisible
    private static List<Zoho_Invoice_Column__mdt> testColumns;

    private final List<Zoho_Invoice_Column__mdt> columns;
    // Column DeveloperName -> validated field path with canonical API names
    private final Map<String, String> fieldPaths = new Map<String, String>();

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

        for (Invoice_New__c invoice : queryInvoices(invoiceIds)) {
            List<String> invoiceCells = new List<String>();
            for (Zoho_Invoice_Column__mdt c : columns) {
                invoiceCells.add(isLineColumn(c) ? '' : cellValue(c, invoice, invoice));
            }

            List<Invoiced_Resource__c> lines = invoice.Invoiced_Resources__r;
            if (lines == null || lines.isEmpty()) {
                rows.add(invoiceCells);
                continue;
            }
            for (Invoiced_Resource__c line : lines) {
                List<String> cells = new List<String>();
                for (Integer i = 0; i < columns.size(); i++) {
                    Zoho_Invoice_Column__mdt c = columns[i];
                    cells.add(isLineColumn(c) ? cellValue(c, line, invoice) : invoiceCells[i]);
                }
                rows.add(cells);
            }
        }
        return rows;
    }

    private String cellValue(Zoho_Invoice_Column__mdt c, SObject source, Invoice_New__c invoice) {
        String value;
        if (c.Use_Export_Value__c && invoice.Type__c == EXPORT_TYPE) {
            value = c.Export_Value__c;
        } else if (c.Value_Source__c == SOURCE_INVOICE_FIELD || c.Value_Source__c == SOURCE_LINE_FIELD) {
            value = formatValue(readPath(source, fieldPaths.get(c.DeveloperName)));
        } else if (c.Value_Source__c == SOURCE_FIXED_TEXT) {
            value = c.Static_Value__c;
        } else if (c.Value_Source__c == SOURCE_CALCULATION) {
            value = ZohoInvoiceExportCalculations.calculate(c.Calculation__c, invoice);
        }
        if (String.isBlank(value)) {
            return '';
        }
        return (c.Prefix__c == null ? '' : c.Prefix__c) + value;
    }

    // Dates as yyyy-MM-dd (same as the Download Zoho File button); numbers without trailing zeros
    @TestVisible
    private static String formatValue(Object raw) {
        if (raw == null) {
            return '';
        }
        if (raw instanceof Date) {
            return String.valueOf((Date) raw);
        }
        if (raw instanceof Datetime) {
            return ((Datetime) raw).format('yyyy-MM-dd');
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

    private List<Invoice_New__c> queryInvoices(List<Id> invoiceIds) {
        Set<String> invoiceFields = new Set<String>{ 'Id', 'Name' };
        invoiceFields.addAll(ZohoInvoiceExportCalculations.REQUIRED_INVOICE_FIELDS);
        Set<String> lineFields = new Set<String>{ 'Id', 'Name' };

        for (Zoho_Invoice_Column__mdt c : columns) {
            String path = fieldPaths.get(c.DeveloperName);
            if (path != null) {
                (isLineColumn(c) ? lineFields : invoiceFields).add(path);
            }
        }

        String soql = 'SELECT ' + String.join(new List<String>(invoiceFields), ', ')
            + ', (SELECT ' + String.join(new List<String>(lineFields), ', ')
            + ' FROM ' + LINE_RELATIONSHIP + ' ORDER BY Name)'
            + ' FROM Invoice_New__c WHERE Id IN :invoiceIds ORDER BY Name';
        // Field paths come only from admin-maintained custom metadata and are validated
        // against the schema. Sharing is enforced (with sharing); field access matches the
        // existing Download Zoho File button.
        return (List<Invoice_New__c>) Database.queryWithBinds(
            soql, new Map<String, Object>{ 'invoiceIds' => invoiceIds }, AccessLevel.SYSTEM_MODE);
    }

    @TestVisible
    private static Object readPath(SObject record, String path) {
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

    private static Boolean isLineColumn(Zoho_Invoice_Column__mdt c) {
        return c.Value_Source__c == SOURCE_LINE_FIELD;
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    private static List<Zoho_Invoice_Column__mdt> loadColumns() {
        List<Zoho_Invoice_Column__mdt> source = testColumns != null ? testColumns : [
            SELECT DeveloperName, MasterLabel, Order__c, Header__c, Active__c, Value_Source__c,
                Field_API_Name__c, Static_Value__c, Calculation__c, Use_Export_Value__c, Export_Value__c, Prefix__c
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
            String source = c.Value_Source__c;
            if (source == SOURCE_INVOICE_FIELD || source == SOURCE_LINE_FIELD) {
                if (String.isBlank(c.Field_API_Name__c)) {
                    errors.add(name + ': Field API Name is required when Value Source is ' + source + '.');
                    continue;
                }
                Schema.SObjectType sourceType = isLineColumn(c)
                    ? Invoiced_Resource__c.SObjectType : Invoice_New__c.SObjectType;
                try {
                    fieldPaths.put(c.DeveloperName, normalizePath(sourceType, c.Field_API_Name__c));
                } catch (ZohoInvoiceExportException e) {
                    errors.add(name + ': ' + e.getMessage());
                }
            } else if (source == SOURCE_CALCULATION) {
                if (!ZohoInvoiceExportCalculations.ALL.contains(c.Calculation__c)) {
                    errors.add(name + ': choose a Calculation when Value Source is Calculation.');
                }
            } else if (source != SOURCE_FIXED_TEXT && source != SOURCE_BLANK) {
                errors.add(name + ': Value Source "' + source + '" is not supported.');
            }
        }
        if (!errors.isEmpty()) {
            throw new ZohoInvoiceExportException('Zoho Invoice Column configuration has errors:\n- ' + String.join(errors, '\n- '));
        }
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
                throw new ZohoInvoiceExportException('"' + parts[i] + '" is not a relationship on ' + current.getDescribe().getName() + '.');
            }
            canonical.add(lookup.getRelationshipName());
            current = lookup.getReferenceTo()[0];
        }
        Schema.SObjectField field = current.getDescribe().fields.getMap().get(parts[parts.size() - 1].trim().toLowerCase());
        if (field == null) {
            throw new ZohoInvoiceExportException('field "' + parts[parts.size() - 1] + '" does not exist on ' + current.getDescribe().getName() + '.');
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