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
