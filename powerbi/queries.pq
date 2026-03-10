// TD SYNNEX | Azure CSP Cost Reporting | Power Query (M)
//
// Before using: define these three parameters in Power BI Desktop
//   Home → Transform Data → Manage Parameters:
//
//   Name                  | Type   | Example value
//   ──────────────────────|────────|─────────────────────────
//   StorageAccountName    | Text   | stcostexports
//   ContainerName         | Text   | cost-exports
//   RootFolderPath        | Text   | exports

let
    StorageAccount = StorageAccountName,
    Container      = ContainerName,
    FolderPath     = RootFolderPath,

    Source          = AzureStorage.Blobs("https://" & StorageAccount & ".blob.core.windows.net"),
    TargetContainer = Source{[Name = Container]}[Data],

    CsvFiles = Table.SelectRows(
        TargetContainer,
        each Text.EndsWith([Name], ".csv")
             and (FolderPath = null or FolderPath = "" or Text.StartsWith([Name], FolderPath & "/"))
    ),

    ParseCsv = (fileContent as binary) as table =>
        let
            Raw      = Csv.Document(fileContent, [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
            Promoted = Table.PromoteHeaders(Raw, [PromoteAllScalars = true])
        in
            Promoted,

    AddedContent   = Table.AddColumn(CsvFiles, "ParsedTable", each ParseCsv([Content])),
    Combined       = Table.Combine(AddedContent[ParsedTable]),

    CleanedColumns = Table.RemoveColumns(
        Combined,
        {"Content", "Name", "Folder Path", "Date accessed", "Date modified", "Date created", "Attributes"},
        MissingField.Ignore
    ),

    // Parse date column
    WithDate = if Table.HasColumns(CleanedColumns, "date")
        then Table.TransformColumns(CleanedColumns, {{"date", each try Date.FromText(_) otherwise null, type date}})
        else CleanedColumns,

    // Parse exchangeRateDate column
    WithExchangeDate = if Table.HasColumns(WithDate, "exchangeRateDate")
        then Table.TransformColumns(WithDate, {{"exchangeRateDate", each try Date.FromText(_) otherwise null, type date}})
        else WithDate,

    // Cast numeric columns — all confirmed present from CSV header
    WithBillingCost = if Table.HasColumns(WithExchangeDate, "costInBillingCurrency")
        then Table.TransformColumns(WithExchangeDate, {{"costInBillingCurrency", each try Number.From(_) otherwise null, type number}})
        else WithExchangeDate,

    WithUSD = if Table.HasColumns(WithBillingCost, "costInUsd")
        then Table.TransformColumns(WithBillingCost, {{"costInUsd", each try Number.From(_) otherwise null, type number}})
        else WithBillingCost,

    WithPricingCost = if Table.HasColumns(WithUSD, "costInPricingCurrency")
        then Table.TransformColumns(WithUSD, {{"costInPricingCurrency", each try Number.From(_) otherwise null, type number}})
        else WithUSD,

    WithExchangeRate = if Table.HasColumns(WithPricingCost, "exchangeRatePricingToBilling")
        then Table.TransformColumns(WithPricingCost, {{"exchangeRatePricingToBilling", each try Number.From(_) otherwise null, type number}})
        else WithPricingCost,

    WithQuantity = if Table.HasColumns(WithExchangeRate, "quantity")
        then Table.TransformColumns(WithExchangeRate, {{"quantity", each try Number.From(_) otherwise null, type number}})
        else WithExchangeRate,

    WithEffectivePrice = if Table.HasColumns(WithQuantity, "effectivePrice")
        then Table.TransformColumns(WithQuantity, {{"effectivePrice", each try Number.From(_) otherwise null, type number}})
        else WithQuantity,

    TypedTable = if Table.HasColumns(WithEffectivePrice, "unitPrice")
        then Table.TransformColumns(WithEffectivePrice, {{"unitPrice", each try Number.From(_) otherwise null, type number}})
        else WithEffectivePrice

in
    TypedTable
