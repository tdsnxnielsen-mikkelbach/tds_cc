# TD SYNNEX – Azure CSP Omkostningsrapportering

> 🇬🇧 [English version](README.md)

Dette kit giver TD SYNNEX og dets forhandlerpartnere en fuldt automatiseret, ende-til-ende Azure-omkostningsrapporteringsløsning bygget på native Microsoft-værktøjer — ingen tredjepartstjenester, ingen manuelle dataudtræk.

Azure Cost Management-eksporter er planlagt til at køre dagligt og skriver CSV-filer direkte til Azure Blob Storage. En Power BI-rapport tilknyttet dette lager læser, kombinerer og modellerer data automatisk ved hver opdatering. Resultatet er et live, selvoppdaterende dashboard, der viser forbrug pr. abonnement, ressourcegruppe, tjeneste og tag — med måned-over-måned-afvigelse, år-over-år-tendenser, budgetopfølgning og månedsprognose som standard.

Løsningen understøtter to deployeringstilstande. I **abonnementstilstand** er eksporter afgrænset til individuelle Azure-abonnementer og godkendt via managed identity — egnet til direkte kunder eller intern brug. I **fakturakontotilstand** er eksporter afgrænset til CSP-fakturakontoen og godkendt via SAS-token, hvilket giver TD SYNNEX mulighed for at hente omkostningsdata på tværs af alle forhandlerkundeabonnementer fra én enkelt deployering. Begge tilstande deployeres via én Bicep-skabelon og et PowerShell- eller Bash-script.

Power BI-rapporten distribueres som både en `.pbix`-enkeltfil og en `.pbip`-projektmappe. Projektformatet gemmer alle rapportlayout- og datamodeldefinitioner som rent tekst i TMDL- og JSON-filer, hvilket gør rapporten fuldt reviderbar og kompatibel med Git-versionskontrol og Microsoft Fabric CI/CD-pipelines. Tema og farvepalet er eksternaliseret til en JSON-fil for nem white-labelling.

---

## Projektstruktur

```
README.md
README.da.md
bicep/
  main.bicep                    Storage-konto, blob-container og RBAC-rolletildeling
  export-sub.bicep              Cost Management-eksport på abonnementsomfang (managed identity)
  export-billing.bicep          Cost Management-eksport på fakturakonto/CSP-omfang (SAS-token)
scripts/
  deploy.ps1                    Samlet PowerShell-deployeringsscript (abonnements- og fakturakontotilstand)
  deploy.sh                     Samlet Bash-deployeringsscript (spejler deploy.ps1)
powerbi/
  tds_cc.pbix                   Enkeltfil Power BI-rapport — åbn direkte i Power BI Desktop
  tds_cc.pbip                   Power BI Project-indgangspunkt — åbn til Git/Fabric-arbejdsflows
  tds_cc.Report/                Rapportartefaktmappe (kræves af .pbip)
    definition.pbir             Rapportdefinition — forbinder rapport med semantisk model
    definition/
      pages/                    Én mappe pr. side med page.json + visuals/
      report.json               Overordnet rapportkonfiguration
    diagramLayout.json          Visuelle canvaspositioner
    StaticResources/
      RegisteredResources/      Registreret TD SYNNEX-temafil
      SharedResources/
        BaseThemes/             Basis Power BI-tema (CY26SU02)
  tds_cc.SemanticModel/         Semantisk modelartefaktmappe (kræves af .pbip)
    DataModel                   Binær datamodelcache
    definition.pbism
    definition/
      tables/
        CostExports.tmdl        Alle målinger, kolonner og Power Query M
        DateTable.tmdl          Beregnet datotabel
      relationships.tmdl        DateTable[Date] → CostExports[date]
      model.tmdl
      expressions.tmdl          Parametre (StorageAccountName osv.)
    .platform                   Fabric-metadata (type: SemanticModel)
  tdsynnex-theme.json           Power BI-farvetema (TD SYNNEX-brand)
  queries.pq                    Power Query (M) — kombinerer daglige CSV-filer fra blob-lager
  calendar.dax                  Datotabel-definition (beregnet tabel)
  measures.dax                  20 DAX-målinger (totaler, MTD/QTD/YTD, MoM, YoY, prognose, budget)
  visuals/                      Sidelayoutdiagrammer ekstraheret fra tds_cc.pbix
```

---

## Deployeringstilstande

| | `subscription` | `billingAccount` |
|---|---|---|
| Eksportomfang | Enkelt abonnement | Fuldt CSP-fakturakonto |
| Godkendelse | Systemtildelt managed identity | SAS-token |
| Nødvendige tilladelser | Abonnements-Contributor | Lejer-niveau / Fakturakonto-ejer |
| Bicep-skabelon | `export-sub.bicep` | `export-billing.bicep` |

**Abonnementstilstand** anbefales til de fleste deployeringer — ingen SAS-token at administrere og ingen tilladelser på lejer-niveau krævet.

---

## Brug (PowerShell)

```powershell
# Abonnementstilstand (anbefalet)
./scripts/deploy.ps1 `
  -Mode subscription `
  -SubscriptionId   <abonnements-id> `
  -ResourceGroup    rg-costexports `
  -StorageAccountName stcostexports `
  -Location         swedencentral

# Fakturakonto/CSP-tilstand
./scripts/deploy.ps1 `
  -Mode billingAccount `
  -SubscriptionId     <abonnements-id> `
  -ResourceGroup      rg-costexports `
  -StorageAccountName stcostexports `
  -BillingAccountId   <fakturakonto-id>
```

## Brug (Bash)

```bash
# Abonnementstilstand (anbefalet)
bash ./scripts/deploy.sh \
  --mode subscription \
  --subscription-id      <abonnements-id> \
  --resource-group       rg-costexports \
  --storage-account-name stcostexports \
  --location             swedencentral

# Fakturakonto/CSP-tilstand
bash ./scripts/deploy.sh \
  --mode billingAccount \
  --subscription-id      <abonnements-id> \
  --resource-group       rg-costexports \
  --storage-account-name stcostexports \
  --billing-account-id   <fakturakonto-id>
```

---

## Valgfrie parametre (begge scripts)

| Parameter | Standard | Beskrivelse |
|---|---|---|
| `ContainerName` / `--container-name` | `cost-exports` | Navn på blob-container |
| `ExportName` / `--export-name` | `daily-cost-export` | Navn på eksportjobbet |
| `RootFolderPath` / `--root-folder-path` | `exports` | Mappe inde i containeren |
| `Format` / `--format` | `Csv` | `Csv` eller `Parquet` |
| `DefinitionType` / `--definition-type` | `ActualCost` | `ActualCost`, `AmortizedCost`, `FocusCost`, `Usage` |
| `Granularity` / `--granularity` | `Daily` | `Daily` eller `Monthly` |
| `Timeframe` / `--timeframe` | `MonthToDate` | Se tilladte værdier i scriptet |
| `Recurrence` / `--recurrence` | `Daily` | `Daily`, `Weekly`, `Monthly`, `Annually` |
| `ScheduleStatus` / `--schedule-status` | `Active` | `Active` eller `Inactive` |

---

## Hvad der deployeres (abonnementstilstand, trin for trin)

1. **Fase 1** — Storage-konto og blob-container oprettes i ressourcegruppen
2. **Fase 2** — Cost Management-eksport oprettes på abonnementsomfang med en systemtildelt managed identity; managed identity-principal-ID'et hentes fra outputtet
3. **Fase 3** — `main.bicep` gendeployeres for at tilføje en `Storage Blob Data Contributor`-rolletildeling, der giver managed identity skriveadgang til storage-kontoen

---

## Power BI-konfiguration

### Inkluderede rapportformater

Mappen `powerbi/` indeholder rapporten i to formater — brug det der passer til dit arbejdsflow:

| Fil / Mappe | Format | Bedst til |
|---|---|---|
| `tds_cc.pbix` | Enkelt binærfil | Hurtig deling, simpel distribution, ingen mappestruktur nødvendig |
| `tds_cc.pbip` + mapper | Power BI Project (PBIP) | Kildekontrol (Git), teamsamarbejde, CI/CD-pipelines |

#### tds_cc.pbix — Enkelt binærfil
Det traditionelle Power BI-filformat. Alt (rapportlayout, datamodel, tema, indstillinger) er pakket ind i én enkelt `.pbix`-fil. Åbn ved at dobbeltklikke eller via **Filer → Åbn** i Power BI Desktop.

#### tds_cc.pbip — Power BI Project-format
Det moderne projektformat introduceret af Microsoft til udviklerarbejdsflows. Åbn `powerbi/tds_cc.pbip` i Power BI Desktop. De tre elementer (`tds_cc.pbip`, `tds_cc.Report/`, `tds_cc.SemanticModel/`) skal forblive i samme mappe — stierne er relative.

**Fordele frem for .pbix:**
- Alle rapportfiler er rent tekst/JSON — fuldt læsbare og diff-bare i Git
- Rapportlayout og datamodel er adskilt i separate mapper
- Kompatibel med Microsoft Fabric Git-integration og Azure DevOps-pipelines
- Anbefalet format hvis flere personer arbejder på rapporten

> **Bemærk:** Begge filer repræsenterer den samme rapport. Behold `.pbip` ved brug af Git eller Fabric, behold `.pbix` til simpel deling.

---

### Trin 1 — Indledende opsætning

1. Åbn Power BI Desktop
2. Anvend TD SYNNEX-temaet: **Vis → Temaer → Gennemse** → vælg `powerbi/tdsynnex-theme.json`
3. Opsæt parametre: **Hjem → Transformér data → Administrer parametre** → opret tre Tekst-parametre:
   - `StorageAccountName` — dit storage-kontonavn (f.eks. `stcostexports`)
   - `ContainerName` — f.eks. `cost-exports`
   - `RootFolderPath` — f.eks. `exports`
4. Indlæs forespørgslen: **Hjem → Ny kilde → Tom forespørgsel → Avanceret editor** → indsæt `powerbi/queries.pq` → klik **Udført** → navngiv forespørgslen `CostExports` → klik **Luk og anvend**
5. Opret datotabellen: **Modellering → Ny tabel** → indsæt udtrykket fra `powerbi/calendar.dax`
6. Markér som datotabel: klik på en celle i `DateTable` → **Tabelværktøjer → Markér som datotabel** → vælg `Date`-kolonnen → klik **OK**
7. Tilføj målinger: **Modellering → Ny måling** → tilføj hver måling enkeltvis fra `powerbi/measures.dax`
8. Gem som `.pbix`

---

### Trin 2 — Opret de 7 sider

Klik på `+`-fanen nederst i Power BI Desktop for at tilføje sider. Navngiv dem præcis:

1. `Cost Overview`
2. `Budgets`
3. `Subscription Breakdown`
4. `Resource Group Breakdown`
5. `Tag Chargeback`
6. `Trend & Forecast`
7. `MoM Waterfall`

---

### Sidelayoutdiagrammer

**Side 1 — Cost Overview**
![Cost Overview](powerbi/visuals/page_Cost_Overview.png)

**Side 2 — Budgets**
![Budgets](powerbi/visuals/page_Budgets.png)

**Side 3 — Subscription Breakdown**
![Subscription Breakdown](powerbi/visuals/page_Subscription_Breakdown.png)

**Side 4 — Resource Group Breakdown**
![Resource Group Breakdown](powerbi/visuals/page_Resource_Group_Breakdown.png)

**Side 5 — Tag Chargeback**
![Tag Chargeback](powerbi/visuals/page_Tag_Chargeback.png)

**Side 6 — Trend & Forecast**
![Trend & Forecast](powerbi/visuals/page_Trend_and_Forecast.png)

**Side 7 — MoM Waterfall**
![MoM Waterfall](powerbi/visuals/page_MoM_Waterfall.png)

---

### Trin 3 — Byg hver side

#### Side 1 — Cost Overview

- **Kort: Total Cost DKK** → Felt: `Total Cost DKK` — viser DKK-formateret værdi med `kr.`-præfiks
- **Kort: Cost MTD** → Felt: `Cost MTD`
- **Kort: Cost YTD** → Felt: `Cost YTD`
- **Kort: Avg Daily Cost** → Felt: `Avg Daily Cost`
- **Kurvediagram: Cost vs Prior Month** → X-akse: `DateTable[MonthYear]` → Y-akse: `Total Cost` og `Cost Prior Month`
- **Kurvediagram: Monthly Trend** → X-akse: `DateTable[MonthYear]` → Y-akse: `Total Cost`
- **Søjlediagram: Top Services by Cost** → Y-akse: `CostExports[meterCategory]` → X-akse: `Total Cost` → Filterpanel: **Top N = 10 efter `Total Cost`**

> Ingen udsnitsværktøjer på denne side — udsnitsværktøjer synkroniseres fra siderne Trend & Forecast og MoM Waterfall via Vis → Synkroniser udsnitsværktøjer.

#### Side 2 — Budgets

- **Kort: Budget** → Felt: `Budget` — rediger `Budget`-målingen for at angive dit månedlige DKK-mål
- **Kort: Budget Variance** → Felt: `Budget Variance` — anvend betinget formatering: rød hvis over budget, grøn hvis under
- **Kort: Budget Variance %** → Felt: `Budget Variance %` — formater som procent
- **Måler: Forbrug vs. Budget** → Værdi: `Total Cost` → Maksimum: `Budget`

#### Side 3 — Subscription Breakdown

- **Søjlediagram: Cost by Subscription** → Y-akse: `CostExports[subscriptionName]` → X-akse: `Total Cost`
- **Tabel** → Kolonner: `CostExports[SubscriptionId]`, `CostExports[subscriptionName]`
- **Kort: Top N Cost Share %** → Felt: `Top N Cost Share %`
- **Kransediagram: Share by Subscription** → Forklaring: `CostExports[subscriptionName]` → Værdier: `Total Cost`

#### Side 4 — Resource Group Breakdown

- **Søjlediagram: Cost by Resource Group** → Y-akse: `CostExports[resourceGroupName]` → X-akse: `Total Cost` → Filterpanel: **Top N = 15**
- **Kort: Avg Monthly Cost** → Felt: `Avg Monthly Cost`
- **Tabel** → Kolonner: `CostExports[resourceGroupName]`, `Total Cost`, `Cost MTD`, `Top N Cost Share %`

#### Side 5 — Tag Chargeback

- **Trækort: Cost by Tag** → Kategori: `CostExports[tags]` → Værdier: `Total Cost`
- **Søjlediagram: Tag Cost Ranked** → Y-akse: `CostExports[tags]` → X-akse: `Total Cost`
- **Kort: Total Cost** → konteksttotal når et tag er valgt
- **Bemærk:** Hvis `tags`-kolonnen indeholder rå JSON (f.eks. `{"environment":"prod"}`), vises værdierne som JSON-strenge. Kontakt din administrator for at opdele tags i separate kolonner via Power Query.

#### Side 6 — Trend & Forecast

- **Kurvediagram: Actual vs Forecast** → X-akse: `DateTable[Date]` (daglig) → Y-akse: `Total Cost` og `Cost Month Forecast`
- **Kurvediagram: Total Cost & Rolling 3M Avg** → X-akse: `DateTable[MonthYear]` → Y-akse: `Total Cost` og `Rolling 3M Avg`
- **Kurvediagram: YoY Comparison** → X-akse: `DateTable[MonthYear]` → Y-akse: `Total Cost` og `Cost Prior Year`
- **Kort: Cost Month Forecast** → Felt: `Cost Month Forecast`
- **Kort: Cost MTD** → Felt: `Cost MTD`
- **Udsnitsværktøj: Datointerval** → Felt: `DateTable[Date]` → Typografi: **Mellem** — synkroniseres på tværs af alle sider

#### Side 7 — MoM Waterfall

- **Vandfaldsdiagram: MoM Variance** → Kategori: `DateTable[MonthYear]` → Y-akse: `Cost MoM Change`
- **Søjlediagram: MoM by Subscription** → Y-akse: `CostExports[subscriptionName]` → X-akse: `Cost MoM Change`
  > Bemærk: På et vandret søjlediagram kræver Power BI **kategori på Y-aksen** og **måling på X-aksen**.
- **Kort: Cost MoM %** → Felt: `Cost MoM %` — formater som procent
- **Kort: Cost MoM Change** → Felt: `Cost MoM Change` — rå DKK-delta
- **Kort: Cost YoY %** → Felt: `Cost YoY %` — formater som procent
- **Udsnitsværktøj: Datointerval** → Felt: `DateTable[Date]` → Typografi: **Mellem** — synkroniseres på tværs af alle sider

---

### Trin 4 — Formatering

- **Valuta:** Brug `Total Cost DKK` på kort med `kr.`-præfiks — brug `Total Cost` overalt ellers
- **Procentmålinger** (MoM %, YoY %, Top N Cost Share %, Budget Variance %): Formatpanel → Billedtekstværdi → Format: `Procent`
- **Betinget formatering på søjlediagrammer:** Formatpanel → Datafarver → **fx** → grøn (lav) til rød (høj)
- **Vandfaldsdiagramfarver:** Formatpanel → Tilstandsfarver — positive søjler grønne, negative røde
- **Synkroniser udsnitsværktøjer:** Vis → Synkroniser udsnitsværktøjer → afkryds alle relevante sider

---

### Trin 5 — Budgetopsætning

`Budget`-målingen er som standard `1000`. For at angive dit faktiske månedlige DKK-mål:

1. Find `Budget`-målingen i Datapanelet → klik på den
2. Erstat `1000` med dit månedlige beløb:
```dax
Budget = 125000
```
3. Tryk Enter — alle Budget Variance- og Budget Variance %-målinger opdateres automatisk

---

### Trin 6 — White-label branding (valgfrit)

Filen `powerbi/tdsynnex-theme.json` styrer alle farver og typografi i rapporten. Rediger den og genanvend den i Power BI Desktop for at rebrande rapporten til en anden organisation.

#### Temafilstruktur

```json
{
  "name": "TD SYNNEX | Azure CSP Cost Reporting",
  "dataColors": [
    "#005C96",
    "#009650",
    "#00AEEF",
    "#7FBA00",
    "#0072C6",
    "#1F7A8C",
    "#4DB6AC",
    "#9CCC65",
    "#F6BD60",
    "#EE6352"
  ],
  "background": "#FFFFFF",
  "foreground": "#1F1F1F",
  "tableAccent": "#005C96"
}
```

| Egenskab | Hvad den styrer | Eksempel |
|---|---|---|
| `name` | Temanavn vist i Power BI's temavælger | `"Contoso \| Azure Cost Reporting"` |
| `dataColors` | De 10 diagramfarver brugt i rækkefølge | Erstat med brandets hex-koder |
| `background` | Baggrundsfarve på rapportcanvas | `"#F8F8F8"` for lys grå |
| `foreground` | Standard tekst- og etiketfarve | `"#1F1F1F"` anbefales |
| `tableAccent` | Fremhævningsfarve på tabeloverskrifter og valgte rækker | Normalt den primære brandfarve |

#### Sådan rebrandes rapporten

1. Åbn `powerbi/tdsynnex-theme.json` i en teksteditor
2. Erstat `name` med dit organisationsnavn
3. Erstat `dataColors`-arrayet med brandets farvepalet — behold alle 10 poster
4. Opdater `tableAccent` til din primære brandfarve
5. Gem filen
6. I Power BI Desktop: **Vis → Temaer → Gennemse** → vælg den redigerede fil
7. Gem rapporten

> **Tip:** Sæt din primære brandfarve som den første post i `dataColors` — den bruges mest fremtrædende.

#### Tilføjelse af virksomhedslogo

Power BI understøtter ikke logoer via tema-JSON — logoer tilføjes som billedvisualiseringer direkte på canvas:

1. Forbered en PNG med transparent baggrund på ca. 200×60 px
2. **Indsæt → Billede** → vælg logofilen
3. Placér i øverste hjørne, sæt baggrund og kant til `Ingen`
4. Kopiér og indsæt på hver side, eller brug en canvas-baggrund: design en 1280×720 px PNG i PowerPoint eller Figma med logo og indstil den via **Formatpanel → Canvas-baggrund → Billede**

> **Bemærk:** Logobilleder indlejres i rapporten når den gemmes og behøver ikke distribueres separat.

---

## Azure-roller og nødvendige tilladelser

### Abonnementstilstand

| Rolle | Omfang | Formål |
|---|---|---|
| `Contributor` | Abonnement | Opret ressourcegruppe, storage-konto, blob-container |
| `Cost Management Contributor` | Abonnement | Opret og administrer Cost Management-eksporter |
| `User Access Administrator` | Abonnement | Tildel `Storage Blob Data Contributor`-rollen til managed identity |
| `Storage Blob Data Contributor` | Storage-konto | Tildeles automatisk af deployeringen — ikke nødvendig for den der deployerer |

> **Bemærk:** `Owner` på abonnementet dækker alle ovenstående.

---

### Fakturakonto/CSP-tilstand

| Rolle | Omfang | Formål |
|---|---|---|
| `Contributor` | Abonnement | Opret ressourcegruppe og storage-konto |
| `Billing Account Owner` eller `Billing Account Contributor` | Fakturakonto | Opret eksporter på fakturakonto-omfang |
| `Global Administrator` | Azure AD-lejer | Kræves til lejer-omfang Bicep-deployering |

---

### Storage-kontotilladelser

| Krav | Detalje |
|---|---|
| Offentlig netværksadgang | Skal være `Aktiveret` |
| Delt nøgleadgang | Skal være `Aktiveret` til SAS-tokengenerering (fakturakontotilstand) |
| `Storage Blob Data Contributor` | Tildelt eksportens managed identity automatisk af fase 3 |
| SAS-tokentilladelser | `acwl` med minimum 1 års udløb (fakturakontotilstand) |

---

### Power BI-tilladelser

| Krav | Detalje |
|---|---|
| Storage-kontoadgang | `Storage Blob Data Reader` eller højere, eller SAS-token/kontonøgle |
| Power BI Desktop | Gratis — ingen Pro-licens kræves lokalt |
| Power BI Service (valgfrit) | Pro- eller Premium-licens kræves til publicering og deling |

---

### Hurtig reference — Minimumroller pr. opgave

| Opgave | Minimumsrolle |
|---|---|
| Kør deployeringsscript (abonnementstilstand) | `Owner` på abonnement |
| Kør deployeringsscript (fakturakontotilstand) | `Global Administrator` + `Billing Account Contributor` |
| Udløs eksport manuelt via CLI | `Cost Management Contributor` på abonnement |
| Læs eksporterede CSV-filer i Power BI | `Storage Blob Data Reader` på storage-konto |
| Udgiv rapport til Power BI Service | Power BI Pro-licens |

---

## CSP-specifik deployeringsvejledning

### Forståelse af CSP-hierarkiet

Som CSP opererer TD SYNNEX inden for et tre-niveau hierarki:

```
TD SYNNEX (Indirekte udbyder)
    └── Forhandlerpartnere
            └── Slutkunder (Abonnementer)
```

**Fakturakontoen lever i TD SYNNEX's egen Azure AD-lejer** — slutkunder og forhandlere har ingen adgang til den. Kun TD SYNNEX interne admins kan deployere eksporter på fakturakonto-omfang.

---

### TD SYNNEX — Fakturakonto-omfang (alle kunder samlet)

```powershell
./scripts/deploy.ps1 `
  -Mode billingAccount `
  -SubscriptionId   <TD-SYNNEX-internt-abonnement> `
  -ResourceGroup    rg-costexports `
  -StorageAccountName stcostexports `
  -BillingAccountId <TD-SYNNEX-fakturakonto-id>
```

De eksporterede data inkluderer `resellerName`, `resellerMpnId` og `subscriptionName`, så Power BI kan opdele omkostninger pr. forhandler og slutkunde.

---

### AOBO — Deployering på vegne af slutkunder

TD SYNNEX har **Admin On Behalf Of (AOBO)**-delegeret adgang til alle slutkundeabonnementer og kan deployere direkte uden kundens involvering.

```bash
az login
az account list --query "[].{Name:name, SubscriptionId:id}" -o table

./scripts/deploy.sh \
  --mode subscription \
  --subscription-id  <kunde-abonnements-id> \
  --resource-group   rg-costexports \
  --storage-account-name stcostexports-<kundekortnavn> \
  --location         westeurope
```

---

### Forhandlerpartnere — Visning af kundeomkostningsdata

#### Option A — TD SYNNEX leverer en filtreret Power BI-rapport (anbefalet)

TD SYNNEX kører eksporten centralt og udgiver rapporten til Power BI Service med Row-Level Security (RLS), så forhandlere kun ser egne kundedata:

```dax
[resellerMpnId] = USERPRINCIPALNAME()
```

#### Option B — Forhandler deployerer sin egen eksport

Hvis forhandleren har DAP- eller GDAP-adgang, kan de selv deployere abonnementstilstandseksporten for deres kunder.

> **GDAP-bemærk:** Ved brug af GDAP skal `Cost Management Contributor`-rollen tildeles eksplicit i Partner Center — GDAP giver ikke blanket Owner-adgang som DAP.

---

### Oversigt — Hvem deployerer hvad

| Scenarie | Deployeret af | Tilstand | Omfang |
|---|---|---|---|
| TD SYNNEX fuldt omkostningsoverblik | TD SYNNEX intern admin | `billingAccount` | Alle forhandlere + kunder |
| TD SYNNEX deployerer for en kunde | TD SYNNEX admin via AOBO | `subscription` | Enkelt kundeabonnement |
| Forhandler deployerer for sine kunder | Forhandler via DAP/GDAP | `subscription` | Enkelt kundeabonnement |
| Slutkunde selvbetjening | Slutkunde | `subscription` | Eget abonnement |

---

### Partner Center — Nyttige links

- Tildel DAP: https://learn.microsoft.com/partner-center/customers-revoke-admin-privileges
- Opsæt GDAP: https://learn.microsoft.com/partner-center/gdap-introduction
- AOBO-oversigt: https://learn.microsoft.com/azure/cost-management-billing/manage/direct-ea-administration
- Cost Management for CSP-partnere: https://learn.microsoft.com/azure/cost-management-billing/costs/get-started-partners
