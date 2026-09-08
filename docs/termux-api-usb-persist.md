# Termux:API USB grant persist (patch recipe)

This repo's `run_sync.sh` already auto-requests USB permission after a
cold-boot deny and fires a **HiDock needs USB OK** notification. That is a
mitigation, not OS-level persist. Stock Termux:API still loses the grant
across reboot.

This document is the concrete recipe for a **custom** Termux:API APK that
can remember the HiDock grant. It does **not** change `run_sync.sh`.
JobScheduler job **834001** remains the supported scheduler.

This repo does not ship a patched APK.

## Why stock Termux:API cannot persist

Android USB host grants are **not** a normal runtime permission. There are
two different mechanisms, and stock Termux:API only uses the temporary one.

1. **No `USB_DEVICE_ATTACHED` `device_filter`.**
   Upstream [`AndroidManifest.xml`](https://github.com/termux/termux-api/blob/master/app/src/main/AndroidManifest.xml)
   declares `android.hardware.usb.host` and a `UsbService`, but no Activity
   has an `android.hardware.usb.action.USB_DEVICE_ATTACHED` intent-filter
   and there is no `res/xml/device_filter.xml`. Without that pair, Android
   never offers the attach dialog that can store a **default** association
   for a specific VID/PID.

2. **`UsbManager.requestPermission()` is session-scoped.**
   [`UsbAPI.java`](https://github.com/termux/termux-api/blob/master/app/src/main/java/com/termux/api/apis/UsbAPI.java)
   calls `usbManager.requestPermission(device, permissionIntent)`. The
   platform documents that as a **temporary** grant for the calling package,
   valid only until the device disconnects (and it is wiped on reboot).
   `termux-usb -r` / the OK dialog from `run_sync.sh` is this path.
   The checkbox on that dialog does **not** create a remembered default.

The remembered-grant path is: Activity + `USB_DEVICE_ATTACHED` +
`device_filter` + the user accepting the **system attach** dialog with
**Use by default / Always** checked. Stock Termux:API never registers that
Activity, so it cannot persist.

## Permission is per-package — must be `com.termux.api`

`UsbManager.hasPermission()` / `openDevice()` are keyed to the **calling
package**. `termux-usb -e` talks to Termux:API (`com.termux.api`); that
process is what must hold the grant.

A companion APK in some other package (even one with a perfect
`device_filter` and a remembered "Use by default") **cannot gift** the
grant to `com.termux.api`. Android has no API for that. The patched APK
must keep package name `com.termux.api` and replace the installed
Termux:API — it is not a sidecar.

## Exact recipe: fork termux-api

Fork / clone <https://github.com/termux/termux-api> and keep the package
name `com.termux.api`.

### 1. `res/xml/device_filter.xml`

Create `app/src/main/res/xml/device_filter.xml`. Android requires
**decimal** `vendor-id` / `product-id` (hex is silently ignored — a
common reason the remember-checkbox appears to do nothing).

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- HiDock P1 mini: VID 0x3887 PID 0x2041 -->
    <usb-device vendor-id="14471" product-id="8257" />

    <!-- Optional older HiDock: VID 0x10D6 PID 0xB00E -->
    <usb-device vendor-id="4310" product-id="45070" />
</resources>
```

P1 mini IDs are required for this project. Include `4310` / `45070` only
if you still have older hardware to document or support. Do **not** add an
empty `<usb-device />` (that matches every USB device) — see
[Upstream](#upstream-675--no-catch-all-filters).

### 2. Manifest: Activity + `USB_DEVICE_ATTACHED` + `directBootAware`

Patch an **Activity** (existing `TermuxAPIMainActivity` is enough; a
dedicated `Theme.NoDisplay` Activity that finishes immediately is nicer
so attach does not foreground the Termux:API UI). It must be
`android:exported="true"` so the system can start it.

```xml
<activity
    android:name=".activities.TermuxAPIMainActivity"
    android:exported="true"
    android:directBootAware="true"
    android:theme="@style/Theme.BaseActivity.DayNight.NoActionBar">
    <intent-filter>
        <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" />
    </intent-filter>
    <meta-data
        android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
        android:resource="@xml/device_filter" />
</activity>
```

`android:directBootAware="true"` is what lets the attach intent be
delivered before first unlock after a cold boot. A BroadcastReceiver
filter is not enough — the remember-default dialog is an Activity path.

Do not add a catch-all filter (no attributes on `<usb-device>`).

### 3. One-time user grant

After installing the patched APK:

1. Plug in the HiDock P1 mini (unplug/replug if it was already connected).
2. Android shows the **attach** dialog for Termux:API / this USB device.
3. Check **Use by default for this USB device** (wording varies: **Always**
   / **Use by default**).
4. Tap **OK**.

That stored default is what survives disconnect and, on a well-behaved
OEM, reboot. The `requestPermission` dialog from `termux-usb -r` is a
different dialog — do not use that one for the remembered grant.

After this, `termux-usb -e` should succeed without a tap. This repo's
auto-request path only runs if `-e` is still denied.

### 4. Signing — this is the hard part

Termux and every plugin share `sharedUserId` `com.termux`. Android will
only install APKs that share that UID if they are signed with **the same
certificate** as the Termux already on the phone.

Sources do **not** share keys:

| Install source | Signing key | Can you sign a custom Termux:API to match? |
|---|---|---|
| [F-Droid](https://f-droid.org/en/packages/com.termux.api/) | F-Droid's private key | **No.** Maintainers do not have this key. |
| [GitHub releases](https://github.com/termux/termux-api/releases) | Termux GitHub/debug key (public test key in `termux-app`) | **Yes**, if your Termux stack is also GitHub-signed. |

A custom APK signed with "whatever keystore you have" will fail to install
over F-Droid Termux:API (`INSTALL_FAILED_UPDATE_INCOMPATIBLE` /
`INSTALL_FAILED_SHARED_USER_INCOMPATIBLE`). Mixing F-Droid Termux with a
GitHub-signed (or self-signed) Termux:API is the same failure.

Practical options:

- **Phone already on GitHub Termux:** sign the patched `com.termux.api`
  with the same GitHub/debug key as that install, then update in place.
- **Phone on F-Droid Termux:** you cannot overlay a custom Termux:API.
  Uninstall Termux **and** every plugin (Termux:API, Termux:Boot, …),
  reinstall the whole stack from **one** source whose key you can use
  (typically GitHub), then install the patched Termux:API signed with
  that same key. This is a full Termux reinstall; `$HOME` does not
  survive unless you back it up first.
- **Self-signed stack:** rebuild Termux + Termux:API (+ any other
  plugins you use) with one keystore. Same uninstall/reinstall cost.

Upstream states this in the Termux:API README: the API app **must** be
signed with the same key as the main Termux app. Call this out before
you spend time on the XML — signing is the part that usually blocks.

## Upstream: #675 / no catch-all filters

See [termux/termux-api#675](https://github.com/termux/termux-api/issues/675).

Maintainer stance ([@agnostic-apollo](https://github.com/agnostic-apollo)):
the official APK will **not** ship a `device_filter` for every gadget
users might plug in, and a catch-all filter (empty `<usb-device />`,
which Android treats as "match every USB device") should **not** be
used. Users who need persist should add the specific VID/PID themselves
and build an APK — that is this recipe.

Apollo also noted that making the whole Termux stack `directBootAware`
is not straightforward (apps normally expect the device unlocked). The
Activity-level flag above is still the documented Android hook for
receiving `USB_DEVICE_ATTACHED` before first unlock; treat it as
best-effort, not a guarantee. See the OEM caveat next.

## OEM caveat: leave-plugged-over-reboot

Even with a correct `device_filter`, remembered default, and
`directBootAware`, **leaving the HiDock plugged in across reboot is
still flaky on some devices**.

Some OEMs do not re-emit `USB_DEVICE_ATTACHED` for a device that was
already attached when the kernel came up, or they re-enumerate late /
only after unlock. Samsung and similar skins are the usual reports.
Unplug/replug after boot re-triggers the attach flow.

If that happens, this repo's existing mitigation still applies: the
JobScheduler job fires, `run_sync.sh` auto-runs `termux-usb -r`, and
you get **HiDock needs USB OK** if a tap is needed. The patched APK
is for true persist when the OEM cooperates; it does not replace that
fallback.
