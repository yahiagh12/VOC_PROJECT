# Setup guide

This guide takes you from an empty Windows 11 PC to a running VOC stack on a
k3s cluster inside WSL2. Steps marked **[admin]** need an elevated PowerShell
(right-click PowerShell → Run as administrator).

---

## 0. Windows toolchain (already done on this PC via Scoop)

- git, kubectl, helm, python — installed under `~/scoop`
- Scoop shims are on the user PATH; new PowerShell sessions see them after
  opening a fresh shell

If you need to recreate on another PC:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
Invoke-RestMethod -Uri 'https://get.scoop.sh' | Invoke-Expression
scoop install git kubectl helm python
```

---

## 1. WSL2 + Ubuntu  **[admin]**

```powershell
# elevated PowerShell
wsl --install -d Ubuntu
wsl --set-default-version 2
wsl --list --verbose          # Ubuntu should show VERSION 2
```

Reboot if prompted. On first `wsl` launch, set the Ubuntu username/password.

---

## 2. Inside WSL Ubuntu: k3s + helm

```bash
# from the Ubuntu shell
sudo apt update && sudo apt -y upgrade

# k3s (single-node). --disable traefik optional if you want to reuse it.
curl -sfL https://get.k3s.io | sh -

# verify
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# make kube config usable without sudo
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
sed -i 's|127.0.0.1|localhost|g' ~/.kube/config   # no-op; clarifies
chmod 600 ~/.kube/config
export KUBECONFIG=~/.kube/config
echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
kubectl get nodes
```

---

## 3. Wire Windows-side kubectl to the WSL2 cluster

WSL2 (mirrored networking on Win11 24H2) exposes k3s on `localhost:6443`.
From a Windows PowerShell:

```powershell
# copy the config from WSL to Windows
wsl cp ~/.kube/config /mnt/c/Users/Regal/.kube/config
# fix the server address so Windows kubectl reaches WSL
(Get-Content C:\Users\Regal\.kube\config) -replace '127\.0\.0\.1','localhost' |
  Set-Content C:\Users\Regal\.kube\config

kubectl get nodes        # should list the WSL node
kubectl get pods -A
```

If `localhost:6443` is not reachable from Windows, port-forward it:

```powershell
# run in its own window; or add a Windows portproxy via netsh (admin)
netsh interface portproxy add v4tov4 listenport=6443 connectaddress=<wsl-ip> connectport=6443  # [admin]
```

Find the WSL IP with `wsl hostname -I`.

---

## 4. Namespaces

```powershell
kubectl apply -f k8s/namespaces/namespaces.yaml
kubectl get ns
```

---

## 5. Deploy core platform

```powershell
# DefectDojo
helm repo add defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts
helm repo update
helm install defectdojo defectdojo/defectdojo -n voc-core -f k8s/defectdojo/values.yaml
kubectl get pods -n voc-core -w

# get the initial admin password
kubectl -n voc-core get secret defectdojo-django-secret -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 -d
# access UI
kubectl -n voc-core port-forward svc/defectdojo-django-svc 8080:8080
# browse http://localhost:8080 -> login as admin -> CHANGE PASSWORD -> store in password manager

# n8n
helm repo add n8n https://charts.n8n.io
helm repo update
helm install n8n n8n/n8n -n voc-core -f k8s/n8n/values.yaml
kubectl -n voc-core port-forward svc/n8n 5678:5678
# browse http://localhost:5678 -> complete initial setup

# TheHive (confirm CE + version first; see k8s/thehive/values.yaml notes)
helm repo add thehive https://thehive-project.github.io/TheHive/
helm repo update
helm install thehive thehive/thehive -n voc-core -f k8s/thehive/values.yaml
kubectl -n voc-core port-forward svc/thehive 9000:9000
```

Commit working `values.yaml` back to the repo after tuning.

---

## 6. Lab targets

```powershell
kubectl apply -f k8s/targets/juice-shop.yaml
kubectl apply -f k8s/targets/dvwa.yaml
kubectl get pods -n targets -w
# sanity check from inside the cluster
kubectl -n scanning run tmp --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sS http://juice-shop.targets.svc.cluster.local:3000 | head -c 200
```

---

## 7. Scanners

Create the DefectDojo API credentials secret the scanners use to upload:

```powershell
kubectl -n scanning create secret generic defectdojo-creds \
  --from-literal=url='http://defectdojo-django-svc.voc-core.svc.cluster.local:8080' \
  --from-literal=api-key='REPLACE_WITH_A_DEFECTDOJO_API_TOKEN'
```

Deploy one scanner at a time; run it manually and confirm findings land in
DefectDojo before moving on:

```powershell
kubectl apply -f scanners/grype-job.yaml
kubectl -n scanning create job manual-grype --from=cronjob/grype
kubectl -n scanning logs job/manual-grype -f
# then ZAP, then Nuclei, same pattern
```

---

## 8. Prioritization service

Build and load the image inside WSL (where docker + k3s's containerd both live):

```bash
# inside WSL Ubuntu
cd /mnt/c/Users/Regal/Desktop/voc/prioritization-service
docker build -t prioritization-service:0.1.0 .
sudo k3s ctr images import - < <(docker save prioritization-service:0.1.0)
```

Then from Windows:

```powershell
kubectl apply -f prioritization-service/deployment.yaml
kubectl -n voc-core port-forward svc/prioritization-service 8000:8000
curl -X POST http://localhost:8000/score
curl http://localhost:8000/state
```

---

## 9. n8n workflow

In the n8n UI: set up credentials (`DefectDojo API`, `TheHive API`) and the
env vars (`DD_URL`, `SLACK_WEBHOOK_URL`, `THEHIVE_URL`). Import
`n8n-workflows/defectdojo-routing.json`, wire credentials to the nodes,
activate, and trigger manually to test. Re-export the working version back
into the repo.

---

## 10. Monitoring

```powershell
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
kubectl apply -f k8s/monitoring/   # Grafana dashboard ConfigMap
helm install kps prometheus-community/kube-prometheus-stack -n monitoring -f k8s/monitoring/values.yaml
kubectl -n monitoring port-forward svc/kps-grafana 3000:80
# login admin / <adminPassword from values.yaml> -> change it
```

---

## Notes

- WSL2 suspends when the Windows session locks, so the cluster is not truly
  always-on. For the PFA demo that is fine.
- Resource ceiling = this PC's RAM minus Windows overhead. If pods get evicted,
  trim TheHive/OpenVAS first.
- Never expose the `targets` namespace outside the cluster.
