# Dataverse Solution Release & View Patch Script
### Hide lookup columns while keeping related columns visible (AADUser scenario included)

---

## 🎯 Purpose

This script was created to solve a specific Model‑Driven App issue:

- Some lookup columns (such as AADUser from the virtual table) **must remain in the view** for related columns (like mail, job title…) to load.
- But displaying the lookup column often causes **duplicates** (example: DisplayName + a copied text column used for sorting/search).
- Dataverse does **not** allow you to permanently hide a lookup column in an unmanaged environment (DEV).
- However, adding `ishidden="1"` **does work inside a Managed package** (UAT/PROD).

👉 **This script automates the process of hiding columns inside Managed solutions while still keeping related columns working — without manually editing XML every time you deploy.**

---

## ✅ What the script does

This PowerShell tool:

1. Connects to your DEV environment  
2. Creates a new version of the solution (auto versioning)  
3. Exports both **Unmanaged** & **Managed** versions  
4. Optionally unpacks the Managed ZIP and applies **view patches**  
   - Locate specific tables & views  
   - Hide one or more columns → `ishidden="1"`  
5. Re‑packs the Managed solution  
6. Generates Deployment Settings files for UAT/PROD  
7. Lets you review these files before deployment  
8. Imports to UAT (and optionally PROD)

Everything is controlled from a simple JSON configuration file.

---

## 🧩 Why automate this?

- DEV automatically removes `ishidden="1"` → you lose the hidden state  
- Manually editing views after every export is error‑prone  
- Lookup‑related columns require the original lookup to stay in the view  
- Hiding the lookup in Managed is the only stable workaround  
- Automation ensures:
  - No mistakes  
  - Repeatability  
  - Multi‑view / multi‑table support  
  - ALM‑friendly pipeline  
  - No hack in DEV

---

## ⚙️ How to use

Run the script:

```powershell
.\Deployement_MultiPatch-DataverseView.ps1 -ConfigPath ".\config.release.json"
```

---

## 📋 JSON Configuration Guide

The `config.release.json` file controls all aspects of the deployment. Here's how to configure it based on your needs:

### Basic Structure

```json
{
  "solution": {
    "solutionName": "MySolution"
  },
  "urls": {
    "dev": "https://org-dev.crm.dynamics.com/",
    "uat": "https://org-uat.crm.dynamics.com/",
    "prd": "https://org.crm.dynamics.com/"
  },
  "auth": {
    "useExistingAuth": true,
    "devName": "DEV_AUTH_ALIAS",
    "uatName": "UAT_AUTH_ALIAS",
    "prdName": "PRD_AUTH_ALIAS"
  },
  "release": {
    "major": "1",
    "minor": "1",
    "deployToProd": false
  },
  "paths": {
    "root": "C:\\Releases\\PowerPlatform",
    "unmanaged": "Unmanaged - Source code",
    "managed": "Managed - Deployed",
    "uatSettings": "UAT - Deployment Settings",
    "prdSettings": "PRD - Deployment Settings",
    "tempUnpack": "temp_unpacked"
  },
  "options": {
    "dryRun": false,
    "keepUnpacked": false,
    "confirmPrompts": true
  },
  "patch": {
    "enabled": true
  },
  "patches": [ ... ]
}
```

### Key Settings

- **solution.solutionName**: Name of your solution in Dataverse  
- **urls.dev/uat/prd**: Environment URLs for DEV, UAT, and Production  
- **auth**: Authentication configuration (use existing auth or specify aliases)  
- **release.major/minor**: Version numbers for the solution  
- **release.deployToProd**: Set to `true` to deploy to Production, `false` for UAT only  
- **paths**: Directory paths where solutions and settings files are stored  
- **options.dryRun**: Preview changes without actually deploying  
- **options.keepUnpacked**: Keep unpacked solution files after patching  
- **options.confirmPrompts**: Show confirmation prompts during execution  
- **patch.enabled**: Set to `true` to apply view patches to the Managed solution  
- **patches**: Array of patch configurations (detailed below)

---

## 🎯 Column Hiding Feature

The **Column Hiding feature** allows you to automatically hide specific columns across multiple views without manual XML editing.

### How It Works

1. **Enable patching**: Set `patch.enabled` to `true` in your config  
2. **Define patch entries**: For each view, add an entry to the `patches` array with the table name, view ID, and columns to hide  
3. **Script applies `ishidden="1"`**: Adds the hidden attribute to matching columns in the view XML  
4. **Works in Managed solutions only**: Hidden columns persist through UAT/PROD deployments  

### Example Configuration

```json
"patch": {
  "enabled": true
},
"patches": [
  {
    "tableName": "account",
    "viewId": "11111111-1111-1111-1111-111111111111",
    "columns": ["aaduser", "displayname"]
  },
  {
    "tableName": "test_1111_referential",
    "viewId": "22222222-2222-2222-2222-222222222222",
    "columns": ["lookupcolumn"]
  }
]
```

### Configuration Breakdown

- **tableName**: The logical name of the table containing the view  
- **viewId**: The unique ID of the view (GUID format) — found in the view's XML or Dataverse  
- **columns**: Array of column logical names to hide in that view  

### Why This Matters

- **Preserves functionality**: Hidden lookup columns still allow related columns to load  
- **Eliminates duplicates**: Hides redundant lookup displays while keeping the data accessible  
- **No manual editing**: Changes apply automatically across all specified views  
- **Managed solution safe**: Unlike unmanaged solutions, Managed packages retain the `ishidden="1"` attribute
