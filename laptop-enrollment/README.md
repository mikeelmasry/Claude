# Laptop Enrollment Automation

Automates enrolling client laptops:

- **Macs → Addigy**, using Apple Business Manager (ABM) Automated Device Enrollment
- **Windows → Intune**, using Windows Autopilot

The goal is **zero-touch**. The user unboxes the laptop, connects to Wi-Fi and signs in, and the
device enrolls itself and installs everything. Your per-device work goes from about 30–60
minutes of hands-on setup to either nothing or one command.

```
                     ┌─────────────── one-time per client ───────────────┐
Mac   purchase ──► ABM ──(abm_assign.py or default server)──► Addigy ──► Setup Assistant auto-enrolls
Win   purchase ──► Autopilot ──(Register-AutopilotDevice.ps1 or reseller)──► Intune ──► OOBE auto-enrolls
```

---

## Biggest win: make reseller purchases enroll themselves

Before using any script, check this for each client. It removes per-device work entirely.

| | What to set up once | Result |
|---|---|---|
| **Mac** | Buy from Apple or an ABM-linked reseller (CDW, etc.) with the client's ABM Organization ID / Reseller Customer Number on the order. In ABM, **Preferences → Your MDM Servers → Default Device Assignment**, set Mac to the client's Addigy server. | New Macs appear in ABM already assigned to Addigy. Nothing to do. |
| **Windows** | Ask the reseller/OEM (Dell, Lenovo, HP, CDW) to **register devices to Autopilot** for the client's tenant, with the group tag. Pliancy can also do this as a CSP partner in Partner Center. | New PCs are in Autopilot before they ship. Nothing to do. |

Use the scripts for everything else: laptops bought elsewhere, re-deploys, replacements, and
devices the reseller missed.

---

## Windows → Intune (Autopilot)

### One-time setup per client tenant

1. **Dynamic device group** (Entra ID → Groups → New group, Membership type: Dynamic Device), e.g. `Autopilot - CONTOSO-STD`:
   ```
   (device.devicePhysicalIds -any (_ -eq "[OrderID]:CONTOSO-STD"))
   ```
2. **Autopilot deployment profile** (Intune → Devices → Windows → Enrollment → Deployment profiles):
   user-driven, Entra joined, hide EULA/privacy/change-account options, standard user, apply
   device name template (e.g. `CON-%SERIAL%`). Assign it to the group above.
3. **Enrollment Status Page** blocking on the required apps and policies, assigned to the same group.
4. Assign your apps and configuration profiles to the group, so the laptop arrives ready to use.
5. **Admin consent for the script**: the first time an Intune admin runs the script in a tenant,
   accept the consent prompt for *Microsoft Graph Command Line Tools* (permission
   `DeviceManagementServiceConfig.ReadWrite.All`). Alternatively, set up your own app
   registration and pass `-ClientId` (plus `-ClientSecret` for unattended runs).

### Per-device: enroll a laptop with a USB stick

Prepare a USB stick once:
```
windows\Register-AutopilotDevice.ps1
windows\Enroll.cmd
windows\clients.cmd        <- copy of clients.example.cmd with your clients filled in
```

On the laptop:
1. Power on. At the first setup screen (region selection), press **Shift+F10**.
2. Connect to the network (Ethernet, or Wi-Fi via the setup screen behind the prompt).
3. Run: `D:\Enroll.cmd contoso` (use the USB drive letter and the client key).
4. Sign in on your phone using the code shown, as an Intune admin for that client.
5. The script uploads the hash, waits for the profile, and reboots. The laptop is ready for the user.

A backup of each hash is saved to `hashes\<client>.csv` on the stick.

### Bulk / offline
If someone else collected hashes (or you saved them to the stick), upload them all at once:
```powershell
.\Register-AutopilotDevice.ps1 -TenantId contosovc.onmicrosoft.com -GroupTag CONTOSO-STD -CsvPath .\hashes\contoso.csv -WaitForProfile
```

### Already set up laptops
Autopilot only runs during OOBE. For a laptop already in use, register it with the script
(run as admin without `-Reboot`), then use **Settings → System → Recovery → Reset this PC**
or an Intune **Autopilot Reset / Wipe**.

---

## Mac → Addigy (Automated Device Enrollment)

### One-time setup per client

1. **Link Addigy to ABM**: in Addigy, add the client's ADE (DEP) token. In ABM this creates an MDM
   server, e.g. "Addigy".
2. In Addigy's ADE settings, **set the default policy** for that token so new devices land in the
   right policy with the right apps, and configure the Setup Assistant / prestage options
   (skip screens, create user account, etc.).
3. **ABM API account**: in ABM, go to **Preferences → API → Create API Account**, give it the Device Manager role,
   and download the private key. Store the key under `macos/keys/<client>.pem` (not in git).
4. Add the client to `macos/clients.json` (copy `clients.example.json`) with the API client ID,
   key ID, key path, and the exact name of the Addigy MDM server in ABM.

### Install
```bash
cd laptop-enrollment/macos
python3 -m pip install -r requirements.txt
cp clients.example.json clients.json   # then fill in
python3 abm_assign.py --client contoso servers   # confirms auth and shows the Addigy server name
```

### Per-device: assign a Mac
```bash
python3 abm_assign.py --client contoso status C02XK1ABJG5H     # in ABM? which server?
python3 abm_assign.py --client contoso assign C02XK1ABJG5H     # assign to Addigy
python3 abm_assign.py --client contoso assign --csv order.csv  # a whole order (serials in column 1)
python3 abm_assign.py --client contoso assign --csv order.csv --dry-run
python3 abm_assign.py --client contoso assign C02XK1ABJG5H --reassign  # move from another MDM server
```
Then power on the Mac (erase it first if it was already set up) and connect to the internet.
It enrolls into Addigy during Setup Assistant.

The output lists each serial as `ASSIGNED`, `OK` (already assigned) or `SKIP`, so you can paste
it straight into the ticket.

### Macs that aren't in ABM
- Macs bought outside ABM can be added with **Apple Configurator for iPhone** (macOS 12+): open
  Configurator, sign in to the client's ABM, and hold the iPhone near the Mac on the Setup Assistant
  "Country or Region" screen. Then run `assign` as above. (The Mac gets a 30-day release window.)
- As a last resort, enroll manually using Addigy's per-policy install command from the
  Addigy console. That isn't supervised ADE, so prefer the steps above.

---

## Security notes

- Credentials never go in git: `clients.json`, `keys/`, `clients.cmd` and hash CSVs are ignored.
- For Windows on a USB stick, use device code sign-in (the default) so no secret sits on removable media.
- ABM private keys grant device-assignment rights for that client. Store them in Pliancy's
  password manager or vault and give each client its own API account.
- Check that Pliancy's policies allow these API integrations for each client before rollout.

## Testing before rollout

These scripts call the Microsoft Graph and Apple Business Manager APIs. Test each client with
**one device** (and `--dry-run` for Macs) before relying on them for a batch.
