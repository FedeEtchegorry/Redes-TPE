# Secure remote access: demo, installation and runbook

Everything needed to install, demo and operate The Store's remote-access lab: an OpenVPN gateway, a CA, a Kubernetes node, an administrator client, a branch office and a dev client on Windows. Installation has two paths (an automatic one with six VirtualBox VMs and a manual one), followed by the live demo and the operation runbook. The design and what was implemented are in [IMPLEMENTATION.md](IMPLEMENTATION.md).

## What gets installed

| Machine | Role | Network | RAM (lab) |
| --- | --- | --- | --- |
| `gw-vpn` | OpenVPN, nftables and DNS | eth0 `203.0.113.10/24` (WAN), eth1 `10.10.0.1/16` (LAN), eth2 `192.168.100.1/24` (management) | 1 GB |
| `k8s-node` | Kubernetes (Kind) and the store | `10.10.10.5/16` | 6 GB |
| `ca` | Certificate authority, isolated | `192.168.100.20/24` (management) | 1 GB |
| `cli-adm` | Sysadmin client | `203.0.113.51/24`, tunnel `10.8.0.20` | 1 GB |
| `gw-sucursal` | Branch gateway (site-to-site) | eth0 `203.0.113.20/24`, eth1 `172.16.20.1/24`, tunnel `10.8.0.30` | 1 GB |
| `host-suc` | Branch host, without a VPN client | `172.16.20.10/24` | 1 GB |
| Windows | Dev client | `203.0.113.50/24`, tunnel `10.8.0.10`-`10.8.0.19` | |

## Requirements

- Ubuntu Server 24.04 LTS on the six VMs, with the packages from its repository (OpenVPN 2.6, EasyRSA 3.1.7, nftables 1.0.9, dnsmasq 2.91). Use the Ubuntu 24.04 repository packages, the tested set.
- k8s-node: Kind v0.31.0 and kubectl v1.35.0.
- Windows 11 with OpenVPN GUI 2.7 and the DCO driver.
- Internet during installation (APT, Kind, images). The demo runs without it.
- The lab host: Windows 11 with **VirtualBox 7.x** (tested with 7.0.20), **Git for Windows** (all scripts run in Git Bash), 16 GB of RAM (the 6 VMs use 11 GB) and 50 GB free in the VirtualBox machine folder.

---

## 1. Installation

### Automatic (VirtualBox lab)

The VMs are linked clones of `the-store-base`, an Ubuntu Server 24.04 installed once. In Git Bash:

```bash
git clone https://github.com/FedeEtchegorry/Redes-TPE.git
cd Redes-TPE/infra/remote-access/scripts
bash setup-lab.sh full --no-pause
```

`full` does, unattended:

1. Creates the two host-only networks (WAN `203.0.113.0/24` and management `192.168.100.0/24`).
2. Creates `the-store-base` if missing: downloads the ISO, verifies its SHA256 and installs Ubuntu unattended.
3. Creates the 6 clones with fixed IPs and MACs.
4. Generates the PKI on `ca` and distributes the bundle and the `.ovpn` profiles.
5. Provisions each VM with [`provision/<vm>.sh`](provision/).
6. Builds the 5 images and deploys the cluster on `k8s-node`.
7. Cuts the VMs' Internet access, runs the verification and takes the `demo` snapshot.

It takes about 2 hours, mostly building the images with 1 vCPU. If the base does not exist, add 15 to 30 minutes. The console can stay quiet for several minutes (ISO download, base install, compilation): it is not stuck. From another terminal: `tail -f ../profiles/setup-lab.log`. It ends with `LABORATORIO DESPLEGADO Y SNAPSHOTEADO`.

Other `setup-lab.sh` commands: `status` (networks, VMs, tunnels and pods), `verify` (end-to-end tests), `start`, `stop` and `reset-demo`.

To enter a VM once the lab has no Internet:

```bash
ssh -i ../profiles/host_admin_ed25519 home@192.168.100.1    # gw-vpn
```

User `home` and password `bishbashbosh` (change them with `GUEST_USER` and `GUEST_PASS`).

To rebuild the 6 VMs and the PKI without reinstalling Ubuntu: `RECREATE=1 bash setup-lab.sh full --no-pause` (in PowerShell, define `$env:RECREATE = '1'` first and call `"C:\Program Files\Git\bin\bash.exe"`). To start from zero including the base, delete the VMs first and the base after, because the clones depend on it:

```bash
VB="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
for vm in gw-vpn k8s-node ca cli-adm gw-sucursal host-suc; do "$VB" unregistervm $vm --delete; done
"$VB" unregistervm the-store-base --delete
```

The files generated on the host (SSH keys, `.ovpn`, bundle and logs) are in `profiles/` and `bundles/`, ignored by git.

| File | Function |
| --- | --- |
| [`scripts/setup-lab.sh`](scripts/setup-lab.sh) | Orchestrates the whole lab: `full`, `status`, `verify`, `reset-demo`, `start`, `stop` and `eval` |
| [`scripts/virtualbox.sh`](scripts/virtualbox.sh) | Networks, base, clones, MACs, Internet cut (`offline`) and snapshots |
| [`scripts/lab-common.sh`](scripts/lab-common.sh) | Shared by the other scripts: SSH, VM helpers and the `chk_*` checks of CU1-CU6 (one definition, used by `eval.sh` and `demo.sh`) |
| [`scripts/eval.sh`](scripts/eval.sh) | Runs the `chk_*` checks silently, as a pass/fail evaluation of CU1-CU6 |
| [`scripts/demo.sh`](scripts/demo.sh) | Guided live demo, case by case: the same `chk_*` checks, showing each command and its raw output |
| [`scripts/cu2-windows.ps1`](scripts/cu2-windows.ps1) | CU2 test from the Windows client |
| [`scripts/pki.sh`](scripts/pki.sh) | CA, certificates, `.ovpn` profiles, revocation and CRL |
| [`scripts/sysadmin-kubeconfig.sh`](scripts/sysadmin-kubeconfig.sh) | Sysadmin kubeconfig with a limited-lifetime token |
| [`provision/*.sh`](provision/) | Configuration of each VM |

### Manual

Order: CA, gw-vpn, cli-adm, branch, k8s-node and Windows. Each step ends with a check. Every VM needs a copy of the repository, and the scripts need the MAC address of each interface, lowercase with colons (`ip -br link`): they name the interfaces by MAC and reject one that does not exist.

#### 1. CA

Connected only to the management network. Install as root (`sudo -i`) from the repository copy: [`ca.sh`](provision/ca.sh) leaves in `/root/.ssh` the key the CA will use to publish the CRL on gw-vpn, and installs the packages and the network.

```bash
ssh-keygen -t ed25519 -N '' -f /root/ca_key
bash infra/remote-access/provision/ca.sh /root/ca_key MAC_ETH0
```

Create the CA and issue the certificates. EasyRSA asks for the CA key password. Keep `CA_DIR` with a protected backup: if that key is lost, everything must be issued again. Issue gw-sucursal **before** exporting the bundle, because the bundle carries the CCD files.

```bash
CA_DIR="$HOME/the-store-ca"
PKI_SH=infra/remote-access/scripts/pki.sh
bash "$PKI_SH" "$CA_DIR" init
bash "$PKI_SH" "$CA_DIR" issue-server
bash "$PKI_SH" "$CA_DIR" issue-client dev-01 dev 10
bash "$PKI_SH" "$CA_DIR" issue-client admin-01 sysadmin 20
bash "$PKI_SH" "$CA_DIR" issue-client gw-sucursal sucursal 30
bash "$PKI_SH" "$CA_DIR" export-server "$HOME/gateway-bundle"
mkdir -m 700 "$HOME/profiles"
for c in dev-01 admin-01 gw-sucursal; do bash "$PKI_SH" "$CA_DIR" export-client "$c" "$HOME/profiles/$c.ovpn"; done
```

The tunnel IP sets the role: dev `.10-.19`, sysadmin `.20-.29` and branch `.30`. Each `.ovpn` carries its holder's private key: hand it only to that person, through an out-of-band channel.

Check: `ls "$HOME/profiles"` shows the three profiles and `ls "$HOME/gateway-bundle"` has no `ca.key`.

#### 2. gw-vpn

With the management network up (`192.168.100.1` on gw-vpn and `.20` on the CA), put the administrator's public key in `~/.ssh/authorized_keys` on gw-vpn: the script turns off SSH password login.

```bash
# On the CA
scp -r "$HOME/gateway-bundle" USER@192.168.100.1:/tmp/the-store-bundle
scp /root/.ssh/id_ed25519.pub USER@192.168.100.1:/tmp/ca.pub
# On gw-vpn
sudo bash infra/remote-access/provision/gw-vpn.sh /tmp/the-store-bundle /tmp/ca.pub MAC_ETH0 MAC_ETH1 MAC_ETH2
rm -r /tmp/the-store-bundle
sudo reboot
```

The bundle carries gw-vpn's private key: delete it on the CA as well (`rm -r "$HOME/gateway-bundle"`); the CA can export it again. After the reboot, check on gw-vpn:

```bash
sudo systemctl is-active nftables dnsmasq openvpn-server@the-store   # three "active"
sudo ss -lntup   # OpenVPN only on 203.0.113.10:1194/udp and SSH only on 192.168.100.1:22
```

On the CA, accept gw-vpn's SSH fingerprint once so `publish-crl` works: `ssh the-store-crl@192.168.100.1 'id -un'`.

To add a client later: issue it, export a new bundle, copy it and rerun the script. It replaces the CCD files and keeps the installed CRL, so an old bundle never undoes a revocation.

#### 3. cli-adm

Copy `admin-01.ovpn` from the CA. The SSH key the sysadmin uses to enter k8s-node is generated here, so no private key travels.

```bash
ssh-keygen -t ed25519
sudo bash infra/remote-access/provision/cli-adm.sh admin-01.ovpn MAC_ETH0
sudo netplan apply
```

#### 4. Branch

Copy `gw-sucursal.ovpn` to gw-sucursal. host-suc has no VPN client: it only receives its network, with gw-sucursal as gateway and DNS.

```bash
# On gw-sucursal
sudo bash infra/remote-access/provision/gw-sucursal.sh gw-sucursal.ovpn MAC_ETH0 MAC_ETH1
sudo reboot
# On host-suc
sudo bash infra/remote-access/provision/host-suc.sh MAC_ETH0
sudo netplan apply
```

Check on gw-sucursal: `sudo systemctl is-active nftables dnsmasq openvpn-client@the-store` and `ip -br address` with `tun0` on `10.8.0.30`.

#### 5. k8s-node

This machine needs Internet in this step (APT, Kind, images): give it a temporary NAT NIC and remove it when done. Copy cli-adm's public key (`~/.ssh/id_ed25519.pub`) as `admin-01.pub`.

```bash
sudo bash infra/remote-access/provision/k8s-node.sh admin-01.pub MAC_ETH0   # Docker, SSH key and network
sudo netplan apply
sudo usermod -aG docker "$USER"   # log out and back in
curl -fLo kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
curl -fLO https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl
sudo install kind kubectl /usr/local/bin/
./local.sh create-cluster --remote-access --skip-tests
bash infra/remote-access/tests/kubernetes.sh   # apiserver, five hosts through the Ingress and permissions
bash infra/remote-access/scripts/sysadmin-kubeconfig.sh sysadmin.kubeconfig
```

Copy `sysadmin.kubeconfig` to cli-adm as `~/.kube/config` (mode 600) and install kubectl there. It is the only kubeconfig that leaves k8s-node and it only reads `the-store`. The token expires: to renew it, repeat the last command.

#### 6. Windows (dev)

Import `dev-01.ovpn` into OpenVPN GUI 2.7 and connect. The server pushes split DNS and OpenVPN creates the NRPT rule for `*.the-store.internal`.

#### 7. Check

| From | Command | Expected |
| --- | --- | --- |
| Windows, connected | `curl.exe --noproxy '*' http://catalog.the-store.internal/catalog/products` | product list; also open `http://ui.the-store.internal` |
| Windows, connected | `Test-NetConnection 10.10.10.5 -Port 22` | fails: dev only has HTTP |
| cli-adm, connected | `kubectl -n the-store get pods` and `ssh root@10.10.10.5` | pods listed and an SSH session |
| host-suc | `curl --noproxy '*' http://ui.the-store.internal/ -o /dev/null` | answers, with no VPN client |

---

## 2. Live demo

[`scripts/demo.sh`](scripts/demo.sh) walks through the six use cases (CU1-CU6), one at a time, and shows the real output of each command against the lab's six VMs and the Windows host, which plays the remote developer. Each step waits for ENTER, so you can comment while showing.

Before starting, check:

| Requirement | How to check |
|-------------|--------------|
| OpenVPN GUI 2.7 with the DCO driver | PowerShell: `Test-Path "$env:ProgramFiles\OpenVPN\bin\openvpn-gui.exe"`; check the executable's version |
| Lab built, with the `demo` snapshot on the VMs | `"$VB" snapshot gw-vpn list` shows `demo` (with `VB` defined as in the [delete commands](#automatic-virtualbox-lab)) |
| Lab running | `bash setup-lab.sh status`: the 6 VMs running, and `admin-01` and `gw-sucursal` in `CLIENT_LIST` |
| Files generated by `full` | `ls ../profiles`: `dev-02.ovpn` and `host_admin_ed25519` |

### Run

From Git Bash, in `infra/remote-access/scripts/`:

```bash
bash setup-lab.sh start        # starts the 6 VMs and waits for tunnels and microservices
bash demo.sh                   # menu: 1 to 6 one case, 7 all, q quit
bash demo.sh cu1               # one case: cu1 to cu6
bash demo.sh todo              # CU1, CU2, CU3, CU5, CU6 and CU4
```

> **Connect `dev-02` before CU2.** CU2 to CU5 use the Windows client: import `infra/remote-access/profiles/dev-02.ovpn` into OpenVPN GUI and connect. Each case confirms the tunnel with `curl http://ui.the-store.internal/home` and warns if it is missing. CU1 and CU6 do not need it.

> **Verdicts.** Below each output the script prints `[OK]` or `[FALLO]` depending on what should be seen. Each case ends with `Resultado CUn: X correctas, Y fallidas`, `todo` ends with `Verificaciones: X correctas, Y fallidas`, and the script exits with code 1 if any check fails.

> **Pauses and confirmation.** The script waits for ENTER between steps. `DEMO_AUTO=1 bash demo.sh todo` runs straight through and skips the CU4 confirmation.

> **CU4 revokes the certificate of `dev-02`, the client connected on Windows.** It asks for confirmation (`[s/N]`) and first syncs the clocks of `ca` and `gw-vpn` with the host's, because OpenVPN rejects a CRL dated in the future. To return to the initial state before each run: `bash setup-lab.sh reset-demo`, which restores the `demo` snapshot and renews the CRL and the sysadmin kubeconfig.

> **CU1 switches off the tunnel of `cli-adm`** (`admin-01`) for a few seconds to see the lab as a WAN host, and brings it back at the end, also if the script is interrupted. If it stays down: `ssh` to `cli-adm` and `sudo systemctl start openvpn-client@the-store`.

> **CU2 opens the store in the browser** for the manual purchase flow (with `DEMO_AUTO=1` it does not).

> **Another dev client.** `DEV_CLIENT` and `DEV_IP` change the profile and the tunnel IP (default `dev-02` and `10.8.0.11`).

### Cases

| # | Command | What it shows |
|---|---------|---------------|
| 1 | `demo.sh cu1` | `cli-adm` with its tunnel switched off, as a WAN host: `nmap` TCP scan of `gw-vpn` finds no open port and the drops show in the kernel log; SSH gets no answer; `nmap` UDP only says `open\|filtered` and a datagram without the `tls-crypt` key returns 0 bytes; `10.10.10.5:80/22/6443` are unreachable without a route and still dropped (`forward drop`) with a manual route through the gateway; `gw-vpn` listens only on what is planned and OpenVPN runs unprivileged; the nftables rules. At the end the tunnel of `cli-adm` is brought back |
| 2 | `demo.sh cu2` | Enrollment on the CA (public certificate, issuer, validity, CCD) and the `.ovpn` profile structure; with `dev-02` connected: tunnel IP and a route only to `10.10.10.5`; the NRPT rule that sends only `.the-store.internal` to `10.8.0.1`; `gw-vpn` sees the client with its fixed IP and its log shows the certificate verification; DNS resolves the zone and rejects `example.com`; the catalog and the UI answer, an item goes into a cart through the API, and the browser opens the store for the manual purchase flow |
| 3 | `demo.sh cu3` | The CCD files and the nftables forward rules per IP range. Dev: `10.10.10.5:80` open, `:22`, `:6443` and `10.8.0.1:22` blocked and audited (`forward drop`), and the five microservices answer HTTP 200. Sysadmin from `cli-adm`: same destination with 80, 22 and 6443 open, SSH to the node, `kubectl get pods` and logs, the RBAC matrix (`list pods` yes; `get secrets`, `delete pods`, `exec`, `kube-system` no) and no access to `gw-vpn` or the CA |
| 4 | `demo.sh cu4` | Three clients connected and the sysadmin operating. `pki.sh revoke` on the CA (the CRL changes only there and `dev-02` stays connected), then `publish-crl`: the CRL is installed and the session is cut. `dev-02` disappears, `admin-01` and `gw-sucursal` stay, `kubectl` keeps working and Windows loses the store. The revoked profile tries to reconnect from `cli-adm` and the OpenVPN log shows `certificate revoked` |
| 5 | `demo.sh cu5` | Simultaneous capture on `gw-vpn` while Windows requests the UI and resolves names: on `eth0` only encrypted UDP/1194 with no names; on `eth1` the same traffic is readable HTTP; on `tun0` only `.the-store.internal` queries arrive (`google.com` does not). The Windows default route stays local and only `10.10.10.5/32` goes through the VPN |
| 6 | `demo.sh cu6` | `gw-sucursal` with its tunnel, the route and `iroute` on `gw-vpn`, no NAT and only `172.16.20.0/24` to `10.10.10.5:80` forwarded. `host-suc` has no OpenVPN client; its DNS at `172.16.20.1` resolves the five services (all answer HTTP 200); `10.10.10.5:22`, `:6443` and `172.16.20.1:22` are blocked. Between the gateways only UDP/1194 without names flows, and on `tun0` the source `172.16.20.10` is preserved |

`todo` ends with CU4 because revoking `dev-02` cuts the tunnel that CU2, CU3 and CU5 need.

### Automatic verification

| Script | What it does |
|--------|--------------|
| `bash eval.sh --no-pause` | Restores the `demo` snapshot, runs the checks (CU1-CU6, with `dev-01`, `admin-01` and `gw-sucursal` connecting from `cli-adm`), restores again and ends with the `Controles aprobados` total |
| `.\infra\remote-access\scripts\cu2-windows.ps1` | PowerShell **as administrator**, from the repo root: connects `dev-02` in OpenVPN GUI and checks the tunnel IP (`10.8.0.11`), the NRPT rule, internal names, HTTP and the certificate verification in the `gw-vpn` log |

`eval.sh` revokes `dev-01` for real and leaves the VMs running without waiting for them to be ready or renewing credentials: run `bash setup-lab.sh reset-demo` before the demo. Do not run `eval.sh` and `demo.sh` at the same time: both use `cli-adm` and the captures on `gw-vpn`. Each run saves its log in `infra/remote-access/profiles/` (`demo.log`, `eval.log`, `setup-lab.log`).

---

## 3. Runbook

The commands below run on the CA with the variables of [manual step 1](#1-ca) (`CA_DIR`, `PKI_SH`).

### What gw-vpn runs

[`provision/gw-vpn.sh`](provision/gw-vpn.sh) verifies the bundle, the key and the MACs before changing anything. Then it installs `openvpn`, `nftables`, `dnsmasq` and `socat`, the files of [`gateway/`](gateway/) and the `the-store-crl` account, which with sudo can only run `the-store-update-crl`. Services start after the reboot. Drops are logged:

```bash
sudo journalctl -k --grep 'the-store (input|forward) drop'
```

### Revoke a client

With dev-01 and admin-01 connected:

```bash
bash "$PKI_SH" "$CA_DIR" revoke dev-01
bash "$PKI_SH" "$CA_DIR" publish-crl dev-01
```

`revoke` revokes the certificate, generates the CRL and deletes the CCD of dev-01, so its tunnel IP can be assigned again. The CRL on gw-vpn stays the same until it is published, and the open session of dev-01 stays up.

`publish-crl` sends the CRL over SSH, through standard input, to `the-store-crl@192.168.100.1` (`GATEWAY` changes the target), where `the-store-update-crl` runs as root. The CRL travels as data, so root never opens a file chosen by that account. Before installing it, the script checks that:

- the signature belongs to the bundle's CA;
- it has not expired (it warns when it expires in less than 7 days);
- its date is not in the future (if it is, the clocks of the CA and gw-vpn disagree);
- it is newer than the installed one or an identical copy; if two different CRLs share the same second, regenerate and retry.

Then it installs the CRL with an atomic rename and ends, through the *management interface*, the session of each given name. It prints `CRL installed` and, per name, `dev-01: session ended` or `dev-01: not connected`. dev-01 cannot reconnect, because OpenVPN reads `crl.pem` on every connection, and admin-01 stays connected.

### Renew the CRL

The CRL expires after 30 days (`EASYRSA_CRL_DAYS`) and then OpenVPN rejects every client. Nothing renews it: before that date, on the CA, `gen-crl` and `publish-crl` without names disconnect nobody.

```bash
bash "$PKI_SH" "$CA_DIR" gen-crl
bash "$PKI_SH" "$CA_DIR" publish-crl
```

Revoking a certificate leaves the sysadmin's kubectl token (it expires after 24 h) and SSH keys valid.

### Renew certificates

The certificates of gw-vpn and of the clients last 365 days (`EASYRSA_CERT_EXPIRE`), and OpenVPN rejects them when they expire. Nothing renews them either. Before that date, on the CA, `renew` issues a new one with the same key and the same CCD, and `revoke-renewed` revokes the old one once the new one is deployed:

```bash
EASYRSA_BIN=/usr/share/easy-rsa/easyrsa
export EASYRSA_PKI="$CA_DIR/pki" EASYRSA_CERT_EXPIRE=365
"$EASYRSA_BIN" --batch renew gw-vpn    # or a client name, such as dev-01
bash "$PKI_SH" "$CA_DIR" export-server "$HOME/gateway-bundle-2"            # gw-vpn
bash "$PKI_SH" "$CA_DIR" export-client dev-01 "$HOME/profiles/dev-01-2.ovpn"  # client
```

Install the bundle as in [manual step 2](#2-gw-vpn) and restart `openvpn-server@the-store`, which reads its certificate at startup, or hand the new profile to its holder. Then revoke the old one and publish the CRL:

```bash
"$EASYRSA_BIN" --batch revoke-renewed gw-vpn
"$EASYRSA_BIN" --batch gen-crl
bash "$PKI_SH" "$CA_DIR" publish-crl
```

Renewing keeps the private key. If a client's key leaked, `revoke` and a new certificate solve it. If the gw-vpn key leaked, the CA and all the profiles must be rebuilt: `client.conf` does not verify the CRL, and whoever holds gw-vpn's key can impersonate the gateway even with its certificate revoked.

### Tests

The scripts in [`tests/`](tests/) check behavior against real processes and the network; those of `provision.sh` and `pki.sh` read files, because they produce files. [`main.yml`](../../.github/workflows/main.yml) runs them in GitHub Actions and fails if a test is not run by any workflow. The tests marked `sudo` create network namespaces, and acceptance on the VMs and Windows is the live demo above.

| Test | Covers | Requires |
| --- | --- | --- |
| [`tests/dnsmasq.sh`](tests/dnsmasq.sh) | DNS zone: names, NXDOMAIN and REFUSED | `dnsmasq-base`, `bind9-dnsutils` |
| [`tests/pki.sh`](tests/pki.sh) | CA, certificates, CCD, bundle, profiles and CRL | `easy-rsa`, `openvpn` |
| `sudo` [`tests/openvpn.sh`](tests/openvpn.sh) | Real server and clients: ciphers, pushed settings, fixed IPs, captures (CU1, CU5) and revocation (CU4) | `socat`, `tcpdump` |
| `sudo` [`tests/nftables.sh`](tests/nftables.sh) | Flow matrix per role with real connections (CU1, CU3) | `nftables`, `socat` |
| `sudo` [`tests/branch.sh`](tests/branch.sh) | Site-to-site branch (CU6) | `tcpdump` |
| `sudo` [`tests/provision.sh`](tests/provision.sh) | `provision/*.sh` with `DESTDIR` | `openssh-server`, `netplan.io` |
| [`tests/kubernetes.sh`](tests/kubernetes.sh) | apiserver, Ingress hosts and sysadmin permissions | Kind cluster |

---

## More information

- [Repository README](../../README.md): the application and an overview of the remote access.
- [IMPLEMENTATION.md](IMPLEMENTATION.md): architecture, what was implemented and validation.
