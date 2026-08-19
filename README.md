# Outbound Database

Windows Flutter application that converts historical outbound Word (`.docx`) files into a searchable business database.

## What it is designed to do

The source documents contain a mixture of sales/billing, delivery challans, demos, repairs, returns, calibration/service work and spare/consumable movements. The importer recognizes the field variants used across the historical files, including `Product`, `Device`, `Item`, `Transducer`, `Serial Number`, `Serial No`, `Amount`, `Quantity`, `Bill/Billing Address`, `Delivery Address`, `GSTIN` and contact fields.

The application stores four useful business layers:

- **Clients** — deduplicated client/customer master with billing and delivery address, GSTIN, phone and email.
- **Transactions** — dated Sale/Billing, DC/Internal Movement, Demo, Repair/Service and Return records.
- **Equipment & Item Master** — deduplicated products, automatically categorized into Main Equipment, Spares & Accessories, Consumables, Calibration & Service, or Other.
- **Price History** — yearly min/average/max observations for the same product based on extracted amounts.

## Importing

Use **Import → Choose DOCX Files** and select multiple historical Word files at once. The importer saves the batch directly into `%APPDATA%\OutboundDatabase\outbound_database_v2.db`.

Re-importing the same logical transaction is ignored using a transaction fingerprint, so running the import again should not blindly duplicate the entire history.

## Export

The Dashboard has **Export Backup**, which creates a JSON backup in `Documents\OutboundDatabase_exports`.

## Build

GitHub Actions builds the Windows desktop application, packages the actual Flutter `build\windows\x64\runner\Release` output, builds the NSIS installer and uploads both the portable ZIP and installer.
