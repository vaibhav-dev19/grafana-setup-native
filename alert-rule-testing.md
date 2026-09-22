# Alert Rule Testing

Use these commands from a host where Grafana is running on `localhost:3001`. Replace `AUTH` and `API` if your Grafana credentials or URL differ.

## Set all resource alert rules to 10%

This updates the CPU, RAM, disk, and GPU usage rules that match `High ... Usage Alert`. The GPU rule is included only when the installer detected and configured the GPU exporter.

```bash
AUTH='admin:root@1234'; API=http://localhost:3001; T=10
curl -s -u "$AUTH" "$API/api/v1/provisioning/alert-rules" | T="$T" python3 -c "
import json,sys,os
rules=json.load(sys.stdin)
t=float(os.environ['T'])
targets=[r for r in rules if r['title'].startswith('High ') and r['title'].endswith(' Usage Alert')]
for r in targets:
    r['data'][2]['model']['conditions'][0]['evaluator']['params']=[t]
    print(json.dumps(r))
" > /tmp/payloads.jsonl
while IFS= read -r line; do
  uid=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['uid'])")
  code=$(echo "$line" | curl -s -o /dev/null -w '%{http_code}' -X PUT -u "$AUTH" \
    -H 'Content-Type: application/json' \
    -H 'X-Disable-Provenance: true' \
    -d @- "$API/api/v1/provisioning/alert-rules/$uid")
  echo "$uid -> $code"
done < /tmp/payloads.jsonl
```

## Set all resource alert rules to 80%

Run the same command with `T=80`:

```bash
AUTH='admin:root@1234'; API=http://localhost:3001; T=80
curl -s -u "$AUTH" "$API/api/v1/provisioning/alert-rules" | T="$T" python3 -c "
import json,sys,os
rules=json.load(sys.stdin)
t=float(os.environ['T'])
targets=[r for r in rules if r['title'].startswith('High ') and r['title'].endswith(' Usage Alert')]
for r in targets:
    r['data'][2]['model']['conditions'][0]['evaluator']['params']=[t]
    print(json.dumps(r))
" > /tmp/payloads.jsonl
while IFS= read -r line; do
  uid=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['uid'])")
  code=$(echo "$line" | curl -s -o /dev/null -w '%{http_code}' -X PUT -u "$AUTH" \
    -H 'Content-Type: application/json' \
    -H 'X-Disable-Provenance: true' \
    -d @- "$API/api/v1/provisioning/alert-rules/$uid")
  echo "$uid -> $code"
done < /tmp/payloads.jsonl
```

## Check current thresholds

```bash
AUTH='admin:root@1234'; API=http://localhost:3001
curl -s -u "$AUTH" "$API/api/v1/provisioning/alert-rules" | python3 -c "
import json,sys
rules=json.load(sys.stdin)
for r in rules:
    if r['title'].startswith('High ') and r['title'].endswith(' Usage Alert'):
        t=r['data'][2]['model']['conditions'][0]['evaluator']['params']
        print(f\"{r['title']:<25} uid={r['uid']:<10} threshold={t}\")
"
```

## Check whether any resource alerts are firing

The output uses `🔥` for firing, `⏳` for pending, and `✅` for inactive rules.

```bash
AUTH='admin:root@1234'; API=http://localhost:3001
curl -s -u "$AUTH" "$API/api/prometheus/grafana/api/v1/rules" | python3 -c "
import json,sys
data=json.load(sys.stdin)
found=False
for group in data['data']['groups']:
    for rule in group.get('rules', []):
        name=rule.get('name','')
        if name.startswith('High ') and name.endswith(' Usage Alert'):
            state=rule.get('state','unknown')
            marker='🔥' if state=='firing' else ('⏳' if state=='pending' else '✅')
            print(f'{marker} {name:<25} state={state}')
            if state in ('firing','pending'):
                found=True
if not found:
    print('No alerts firing or pending.')
"
```

> **Security:** The example uses the installer's default credentials. Change the Grafana password before using these commands in a production environment, and avoid exposing credentials in shell history or shared scripts.
