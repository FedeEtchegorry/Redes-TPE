# Remote access implementation (The Store)

This document summarizes what was implemented for secure remote access to **The Store**: goals, architecture, files and validation. The microservices code stays as in the initial commit (the small build adjustments are listed in 3.1). Everything new lives in `infra/remote-access/` and in the `--remote-access` flag of `local.sh`.

Related docs:

- [Repository README](../../README.md): the application and an overview of the remote access.
- [Install, demo and runbook](README.md): VirtualBox lab, manual installation, live demo, revocation and renewals, tests.
- [Proposal (reentrega)](../../docs/The%20Store%20-%20Acceso%20Remoto%20Seguro%20-%20Reentrega.md): use cases CU1-CU6, roles and flow matrix.

---

## 1. Overall goal

Give remote users **a single encrypted and authenticated entry point** to the internal store, with:

1. **Mutual authentication**: individual X.509 certificates issued by an isolated CA.
2. **Role-based authorization**: a fixed tunnel IP per role and nftables rules by source IP.
3. **Verifiable revocation**: a CRL for new connections and a session kill for the current one.
4. **Internal DNS and split tunnel**: only `*.the-store.internal` and the node travel through the VPN.
5. **Site-to-site branch**: a whole LAN reaches the store with no VPN client on its hosts.

Everything is versioned in Git and reproducible with `local.sh --remote-access`, the `provision/` scripts and, for the full lab, `scripts/setup-lab.sh`.

---

## 2. Architecture (connection flow)

```text
Dev client (Windows 203.0.113.50)       Sysadmin client (cli-adm 203.0.113.51)
        │                                          │
        └──── OpenVPN UDP 1194 (TLS 1.3, tls-crypt) ┘
                         ▼
gw-vpn   eth0 203.0.113.10 │ tun0 10.8.0.1 │ eth1 10.10.0.1 │ eth2 192.168.100.1
   │  OpenVPN: mTLS + CRL + CCD (fixed IP per role)
   │  nftables: DROP policy, rules by tunnel IP, SNAT to 10.10.0.1
   │  dnsmasq: *.the-store.internal -> 10.10.10.5
   ▼
k8s-node 10.10.10.5
   ├─ :80   Ingress -> ui / catalog / carts / orders / checkout
   ├─ :22   SSH (sysadmin only)
   └─ :6443 kube-apiserver (sysadmin only)
```

Branch and CA:

```text
host-suc 172.16.20.10 (no VPN client; gateway and DNS 172.16.20.1)
   ▼
gw-sucursal  eth1 172.16.20.1 │ tun0 10.8.0.30 │ eth0 203.0.113.20
   └──── OpenVPN tunnel (route + iroute 172.16.20.0/24) ──── gw-vpn

CA 192.168.100.20 (management network only)
   └─ ssh the-store-crl@192.168.100.1 (CRL over stdin) -> kill <CN> on the management socket
```

- The only surface exposed on the WAN is **UDP 1194** on gw-vpn; its SSH listens only on `192.168.100.1`.
- The store's Services stay ClusterIP: they are reached only through the Ingress at `10.10.10.5:80`.
- Networks: WAN `203.0.113.0/24`, tunnel `10.8.0.0/24`, LAN `10.10.0.0/16`, management `192.168.100.0/24`, branch `172.16.20.0/24`.

---

## 3. Implementation

### 3.1 `local.sh --remote-access` and `k8s/`


| File                             | What it is                                                                                                                       |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `local.sh`                       | `--remote-access` flag: creates the cluster with `k8s/kind-cluster.yaml` and, after the deploy, applies the Ingress and the RBAC |
| `k8s/kind-cluster.yaml`          | apiserver on `10.10.10.5:6443`, pod and service CIDRs, port 80 mapped                                                            |
| `k8s/internal-ingress.yaml`      | Five hosts `*.the-store.internal` to `ui`, `catalog`, `carts`, `orders` and `checkout`                                           |
| `k8s/sysadmin-rbac.yaml`         | `sysadmin` ServiceAccount bound to the read-only `view` role on `the-store`                                                      |
| `scripts/sysadmin-kubeconfig.sh` | Kubeconfig with an expiring token (24 h by default)                                                                              |


Compared with the initial commit, `dist/kubernetes.yaml` only lowers the CPU requests (`10m`) and the checkout Dockerfile changes a `chown`.

### 3.2 PKI and CCD (`scripts/pki.sh`)


| Piece                                  | What it does                                                                                           |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `init`, `issue-server`, `issue-client` | EC certificates (365 days) from an isolated, password-protected CA                                     |
| CCD per client                         | Fixed tunnel IP and a single route to `10.10.10.5/32`; `gw-sucursal` also gets `iroute 172.16.20.0/24` |
| `export-server`                        | Bundle for gw-vpn (certificates, keys, `tls-crypt`, CRL, CCD), never with `ca.key`                     |
| `export-client`                        | One `.ovpn` per client with its own credentials                                                        |
| `revoke`, `gen-crl`, `publish-crl`     | Revocation and CRL publishing (section 6)                                                              |


The IP range defines the role: dev `.10-.19`, sysadmin `.20-.29` and branch `.30`.

### 3.3 Gateway `gw-vpn` (`gateway/`)


| File                                          | What it does                                                                                        |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `openvpn/server.conf`                         | UDP 1194, TLS 1.3, AES-256-GCM, `tls-crypt`, CRL, mandatory CCD, split DNS pushed, runs as `nobody` |
| `nftables/nftables.conf`                      | DROP policy on input and forward, rules by tunnel IP, SNAT and logging of drops                     |
| `dnsmasq/the-store.conf`                      | Five host records to `10.10.10.5`, only on `tun0`, no forwarders                                    |
| `ssh/the-store.conf`                          | SSH only on the management address, with keys only                                                  |
| `openvpn/update-crl.sh`, `sudo/the-store-crl` | Safe CRL installation by the `the-store-crl` account                                                |


### 3.4 Branch (`branch/`)

`gw-sucursal` runs its own nftables (DNS from the branch LAN and HTTP to the Ingress through the tunnel, with no NAT and no inbound ports) and its own dnsmasq, which forwards `the-store.internal` to `10.8.0.1`. `host-suc` only gets a network configuration, with `gw-sucursal` as gateway and DNS.

### 3.5 Provisioning and lab

`provision/*.sh` has one script per machine: packages, configuration, services and network by MAC, with everything validated before anything changes. `scripts/setup-lab.sh` and `virtualbox.sh` build and manage the six-VM VirtualBox lab with one command, `eval.sh` runs the automatic checks, `demo.sh` is the guided live demo with `[OK]` or `[FALLO]` verdicts and `cu2-windows.ps1` tests CU2 from the real Windows client. The [scripts table](README.md#automatic-virtualbox-lab) of the guide lists them all.

### 3.6 Tests and CI (`tests/`, `.github/workflows/`)

`tests/` has one script per component: DNS, PKI, OpenVPN, nftables, branch, provisioning and Kubernetes. `main.yml` runs them in GitHub Actions with a `coverage` job (every test must be executed by a workflow), one job per network test and a `deploy` job with Kind. Each test and its requirements are in the [Tests section](README.md#tests) of the guide.

---

## 4. Role-based authorization

Two layers: the **CCD** fixes the tunnel IP and the only route; **nftables** decides which connections pass according to that IP. Routes grant no permissions.


| Source                          | HTTP 80 | SSH 22 | API 6443 | DNS                  | SSH to gw-vpn |
| ------------------------------- | :-------: | :------: | :--------: | :--------------------: | :-------------: |
| dev (`10.8.0.10-.19`)           | yes     | no     | no       | yes                  | no            |
| sysadmin (`10.8.0.20-.29`)      | yes     | yes    | yes      | yes                  | no            |
| branch hosts (`172.16.20.0/24`) | yes     | no     | no       | yes, via gw-sucursal | no            |
| WAN without tunnel              | no      | no     | no       | no                   | no            |
| Management network              | no      | no     | no       | no                   | yes           |


Everything else is dropped and logged (`the-store input drop:` and `the-store forward drop:`). The sysadmin's Kubernetes identity can only read `the-store`, without Secrets or `exec`.

---

## 5. Internal DNS and split tunnel

- gw-vpn answers `*.the-store.internal` with `10.10.10.5` and refuses every other name.
- OpenVPN pushes the zone to clients. On Windows 2.7 with DCO it creates an NRPT rule for `*.the-store.internal`.
- Clients receive no default route: they keep their own Internet and send only `10.10.10.5/32` through the tunnel.
- The branch resolves through `gw-sucursal`, which forwards the zone to `10.8.0.1`.

---

## 6. Revocation (CU4)

Both steps run from the CA with `pki.sh`. `revoke` revokes the certificate, deletes its CCD and regenerates the CRL. `publish-crl` sends the CRL over SSH on the management network to the `the-store-crl` account, which can only run `the-store-update-crl`: it checks the CRL, installs it atomically and kills the named session on the OpenVPN management socket. The revoked client cannot reconnect, because OpenVPN reads the CRL on every connection, and the other sessions stay up. The commands, the CRL and certificate renewals are in the [Runbook](README.md#3-runbook).

---

## 7. Use cases and how they are validated

`scripts/eval.sh` restores the `demo` snapshot, runs the checks against the VMs and restores the snapshot again. `scripts/demo.sh` shows the same cases live.


| Case                | What it demonstrates                                                                                                 |
| ------------------- | -------------------------------------------------------------------------------------------------------------------- |
| CU1 Default deny    | From the WAN, gw-vpn offers no SSH or HTTP; a UDP probe without `tls-crypt` gets no answer; OpenVPN runs as `nobody` |
| CU2 Dev connection  | `dev-01` gets `10.8.0.10`, a route only to the node, resolves names and uses catalog, carts and UI                   |
| CU3 Roles           | Dev cannot reach 22 or 6443; sysadmin gets SSH and a read-only kubectl, and cannot reach gw-vpn or the CA            |
| CU4 Revocation      | One client is revoked and cut; the others keep their sessions                                                        |
| CU5 Confidentiality | The WAN shows only encrypted UDP 1194; behind the gateway the same HTTP is readable                                  |
| CU6 Branch          | `host-suc` reaches the five services without a VPN client; SSH and the API stay blocked                              |


---

## 8. Reaching the store from each client

Internal names resolve only while the tunnel is up, so connect first. The commands for the dev client, the sysadmin client and a branch host are in the [Check table](README.md#7-check) of the guide.

Health endpoints of the five services:

```bash
curl --noproxy '*' http://catalog.the-store.internal/health
curl --noproxy '*' http://checkout.the-store.internal/health
curl --noproxy '*' http://ui.the-store.internal/actuator/health/readiness   # also carts and orders
```

---

## 9. Installation and demo

The [guide](README.md) has the [automatic lab](README.md#automatic-virtualbox-lab), the [manual installation](README.md#manual) and the [live demo](README.md#2-live-demo).

---

## 10. Validation

`eval.sh` ran on the six VMs without Internet and covered:

- CU1-CU6 end to end.
- The branch: the five services answer from `host-suc`.
- Revocation of `dev-01` while `admin-01` and `gw-sucursal` keep their sessions.
- The capture: encrypted UDP 1194 on the WAN and readable HTTP on `eth1`.

The log is `infra/remote-access/profiles/eval.log` (ignored by git). Still open: a recorded run of CU2 with the real Windows client (`cu2-windows.ps1`) and the CI results, which the repo does not keep.
