# 10-minute demo script (Innoverse / stakeholders)

## Prep (before the meeting)

```bash
git clone https://github.com/prasadugamd/POD_RESOURCE_UTIL.git
cd POD_RESOURCE_UTIL
kubectl config current-context   # or: oc whoami --show-context
kubectl top nodes | head         # metrics must work
```

Pick a safe non-prod namespace if possible.

---

## Minute 0–2 — Problem

> “Teams see Pending pods or hot nodes but mix up **scheduler reserved** capacity vs **live idle**. This tool separates them and suggests rightsizing.”

Show the status legend briefly (CRITICAL / RESERVED BUT IDLE / HOT).

---

## Minute 2–6 — Live CLI

```bash
bash ./pod_res_util_agent.sh --mode multicloud <NAMESPACE>
```

Walk through:

1. Detected cloud / pool names  
2. CPU & Memory: Capacity · Reserved · In-Use · Schedulable · Idle  
3. Pool pressure (if any)  
4. Pending pods  
5. Top wasters + Suggested Req  

Point to `reports/pod_res_util_*.txt`.

Optional HTML (still no email):

```bash
bash ./pod_res_util_agent.sh --mode aks-html <NAMESPACE>
```

Open the `.html` under `reports/`.

---

## Minute 6–9 — MCP (if Cursor available)

```bash
cd agent && npm install
# Reload MCP in Cursor — server name: pod-res-util
```

Prompt:

> Call `run_pod_resource_report` with namespaces `["<NAMESPACE>"]` and mode `multicloud`. Summarize pressure and top rightsizing opportunities.

---

## Minute 9–10 — Close

- Email is opt-in; safe for demos  
- Multi-cloud ready (AKS/EKS/GKE/OKE/OCP)  
- Pilot label: sample-based metrics; use p95 for bursty apps  
- Next: adopt on a TC namespace + optional weekly HTML  

**Repo:** https://github.com/prasadugamd/POD_RESOURCE_UTIL
