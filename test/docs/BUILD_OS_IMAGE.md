# Creating a test image

This document explains how to create base OS images and run test runners on them.
This guide is written from the perspective of a Linux user, but it should work on Windows as well.

## Prerequisites

You need to have [QEMU](https://www.qemu.org/) installed.

# Linux

These instructions use Debian, but the process is pretty much the same for any other distribution.

## Creating a virtual machine

On the host, start by creating a disk image and installing Debian on it:

```
wget -O debian.iso https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-11.5.0-amd64-netinst.iso
qemu-img create -f qcow2 ./debian.qcow2 5G
qemu-system-x86_64 -cpu host -accel kvm -m 4096 -smp 2 -cdrom debian.iso -drive file=./debian.qcow2
```

## Installing Linux

Follow the distribution's installation process. The only important detail is to set up the [user](#User) correctly.

### User

The testframework expects there to be a regular user in the guest which it can login as.
The `test-manager` makes no assumptions about the login credentials of this user, but they have to be provided as outlined in the [test-manager configuration specification](../test-manager/docs/config.md).

To better illustrate the remaining steps of the installation process, we assume that a regular system user called `test` has been created.

#### sudo

The user should be able to execute `sudo` without a password.

One way of accomplishing this is to add the `test` user to the `wheel` group
```bash
gpasswd -a test wheel
```

and edit `/etc/sudoers` to allow members of `wheel` to execute commands without a password
```bash
sudo visudo
```

Then comment out
```bash
## Allows people in group wheel to run all commands
# %wheel        ALL=(ALL)       ALL
```

and add
```bash
## Same thing without a password
%wheel  ALL=(ALL)       NOPASSWD: ALL
```

#### ssh

Make sure that `sshd.service` is enabled on boot.
```bash
systemctl enable sshd.service
```

## Finishing setup

Now you are done! If the VM was configured correctly, `test-manager` will be able to install the required dependencies and run the test suite using the new OS image.
Now you should [add your new VM to the test-manager config](./test-manager/README.md#configuring-test-manager)


# Windows

## Windows 10

* Download a Windows 10 ISO: https://www.microsoft.com/software-download/windows10

* On the host, create a new disk image and install Windows on it:

    ```
    mkdir -p os-images
    qemu-img create -f qcow2 ./os-images/windows10.qcow2 32G
    qemu-system-x86_64 -cpu host -accel kvm -m 4096 -smp 2 -cdrom <YOUR ISO HERE> -drive file=./os-images/windows10.qcow2
    ```

## Windows 11

* Download an ISO: https://www.microsoft.com/software-download/windows11

* Create a disk image with at least 64GB of space:

    ```
    mkdir -p os-images
    qemu-img create -f qcow2 ./os-images/windows11.qcow2 64G
    ```

* Windows 11 requires a TPM as well as secure boot to be enabled (and thus UEFI). For TPM, use the
  emulator SWTPM:

    ```
    mkdir -p .tpm
    swtpm socket -t  --ctrl type=unixio,path=".tpm/tpmsock"  --tpmstate ".tpm" --tpm2 -d
    ```

* For UEFI, use OVMF, which is available in the `edk2-ovmf` package.

  `OVMF_VARS` is used writeable UEFI variables. Copy it to the root directory:

  ```
  cp /usr/share/OVMF/OVMF_VARS.secboot.fd .
  ```

* Launch the VM and install Windows:

  ```
  qemu-system-x86_64 -cpu host -accel kvm -m 4096 -smp 2 -cdrom <YOUR ISO HERE> -drive file=./os-images/windows11.qcow2 \
  -tpmdev emulator,id=tpm0,chardev=chrtpm -chardev socket,id=chrtpm,path=".tpm/tpmsock" -device tpm-tis,tpmdev=tpm0 \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE.secboot.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=./OVMF_VARS.secboot.fd \
  -machine q35,smm=on
  ```

## Notes on local accounts

Logging in on a Microsoft account should not be necessary. A local account is sufficient.

If you are asked to log in and there is no option to create a local account, try to disconnect
from the network before trying again:

1. Press shift-F10 to open a command prompt.
1. Type `ipconfig /release` and press enter.

If you are forced to connect to a network during the install, and cannot opt to use a local account,
do the following:

1. Press shift-F10 to open a command prompt.
1. Type `oobe\BypassNRO` and press enter.


### Bootstrapping the test runner

The test runner needs to be started on boot, with the test runner image mounted at `E:`.
This can be achieved as follows:

* Restart the VM:

    ```
    qemu-system-x86_64 -cpu host -accel kvm -m 4096 -smp 2 -drive file="./os-images/windows10.qcow2"
    ```

* In the guest admin `cmd`, add the test runner as a scheduled task:

    ```
    schtasks /create /tn "Mullvad Test Runner" /sc onlogon /tr "\"E:\test-runner.exe\" \\.\COM1 serve" /rl highest
    ```

    Further changes might be required to prevent the task from stopping unexpectedly. In the
    Task Scheduler (`taskschd.msc`), change the following settings for the runner task:

    * Disable "Start the task only if the computer is on AC power".
    * Disable "Stop task if it runs longer than ...".
    * Enable "Run task as soon as possible after a scheduled start is missed".
    * Enable "If the task fails, restart every: 1 minute".

* In the guest, disable Windows Update.

    * Open `services.msc`.

    * Open the properties for `Windows Update`.

    * Set "Startup type" to "Disabled". Also, click "stop".

* In the guest, disable SmartScreen.

    * Go to "Reputation-based protection settings" under
      Start > Settings > Update & Security > Windows Security > App & browser control.

    * Set "Check apps and files" to off.

* (Windows 11) In the guest, disable Smart App Control

    * Go to "Smart App Control" under
      Start > Settings > Privacy & security > Windows Security > App & browser control.

    * Set it to off.

* Enable autologon by creating or editing the following registry values (all of type REG_SZ):

    * Set the current user in
      `HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\DefaultUserName`.

    * Set the password in
      `HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\DefaultPassword`.

    * Set `HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\AutoAdminLogon` to 1.

* Shut down.

## Finishing setup

Now you are done! If the VM was configured correctly, `test-manager` will be able to run the test suite using the new OS image.
Now you should [add your new VM to the test-manager config](./test-manager/README.md#configuring-test-manager)

# macOS 🚧

_Instructions for building an OS image based on macOS are still under construction._

# Legacy methods

The following instructions are either completely deprecated or needed very seldom. We keep these for future reference.

# Linux

## Test runner dependencies

`xvfb` and `wireguard-tools` must be installed on the guest system.
You will also need some additional libraries, but these are most likely already installed if `gnome` is installed.

### Debian/Ubuntu

```bash
apt install wireguard-tools xvfb libnss3 libgbm1 libasound2 libatk1.0-0 libatk-bridge2.0-0 libcups2 libgtk-3-0
```

### Fedora

```bash
dnf install wireguard-tools xorg-x11-server-Xvfb nss mesa-libgbm atk alsa-lib-devel at-spi2-atk gtk3
```

## Creating a test runner image (Legacy method)

The [build-runner-image.sh](./scripts/build-runner-image.sh) script produces a
virtual disk containing the test runner binaries, which must be mounted when
starting the guest OS. They are used `build-runner-image.sh` assumes that an environment
variable `$TARGET` is set to one of the following values:
`x86_64-unknown-linux-gnu`, `x86_64-pc-windows-gnu` depending on which platform
you want to build a testrunner-image for.

## Bootstrapping test runner (Legacy method)

The testing image needs to be mounted to `/opt/testing`, and the test runner needs to be started on
boot.

* In the guest, create a mount point for the runner: `mkdir -p /opt/testing`.

* Add an entry to `/etc/fstab`:

    ```
    # Mount testing image
    /dev/sdb /opt/testing ext4 defaults 0 1
    ```

* Create a systemd service that starts the test runner, `/etc/systemd/system/testrunner.service`:

    ```
    [Unit]
    Description=Mullvad Test Runner

    [Service]
    ExecStart=/opt/testing/test-runner /dev/ttyS0 serve

    [Install]
    WantedBy=multi-user.target
    ```

* Enable the service: `systemctl enable testrunner.service`.

### Note about SELinux (Fedora)

SELinux prevents services from executing files that do not have the `bin_t` attribute set. Building
the test runner image strips extended file attributes, and `e2tools` does not yet support setting
these. As a workaround, we currently need to reapply these on each boot.

First, set `bin_t` for all files in `/opt/testing`:

```
semanage fcontext -a -t bin_t "/opt/testing/.*"
```

Secondly, update the systemd unit file to run `restorecon` before the `test-runner`, using the
`ExecStartPre` option:

```
[Unit]
Description=Mullvad Test Runner

[Service]
ExecStartPre=restorecon -v "/opt/testing/*"
ExecStart=/opt/testing/test-runner /dev/ttyS0 serve

[Install]
WantedBy=multi-user.target
```
