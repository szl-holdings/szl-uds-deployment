# Copyright 2026 SZL Holdings
# SPDX-License-Identifier: Apache-2.0
#
# box-watch-stubs.sh — shared fake-cluster harness sourced by the box-watcher
# end-to-end guards (scripts/*-e2e-guard.sh).
#
# WHY THIS EXISTS
# Several box-scripts watchers (szl-receipts-orphan-watch, szl-core-rightsize,
# istiod-fit-strategy, ...) shell out to `k3d` / `kubectl` / `helm` to inspect
# and (for the self-heal ones) PATCH the live uds-szl-demo cluster. To drive the
# REAL watcher end-to-end in CI with no cluster and no root, we put fake k3d,
# kubectl and helm executables on $PATH. They are driven entirely by control
# files the guard writes into a control dir, and every `kubectl patch` is
# appended to "<ctrl>/patches" so a guard can assert EXACTLY which resources a
# watcher tried to repair (or that it correctly patched nothing).
#
# make_k8s_stubs <bindir>
#   Writes fake k3d/kubectl/helm into <bindir> (chmod +x). The fakes read their
#   control dir from $STUB_CTRL at run time, so the caller must:
#     export STUB_CTRL="<ctrldir>"
#     export PATH="<bindir>:$PATH"
#   before running the watcher under test.
#
# Control files the fakes honour (all optional; absent = sane default):
#   k3d:
#     <ctrl>/k3d_absent        present  -> `k3d kubeconfig write` fails (cluster
#                                          absent/stopped; watcher must no-op)
#     <ctrl>/kubeconfig                  echoed as the kubeconfig path otherwise
#   kubectl:
#     <ctrl>/readyz_rc          int     -> exit code for `get --raw=/readyz`
#                                          (default 0 = reachable; 1 = down)
#     <ctrl>/deploy_rows        text    -> body of `get deploy -A -o jsonpath`
#     <ctrl>/deploy_<ns>_<name>_present   present -> deploy exists (bare get ok)
#     <ctrl>/deploy_<ns>_<name>_replicas  value of {.spec.replicas}
#     <ctrl>/deploy_<ns>_<name>_stype     value of {.spec.strategy.type}
#     <ctrl>/deploy_<ns>_<name>_surge     value of {.spec.strategy.rollingUpdate.maxSurge}
#     <ctrl>/hpa_<ns>_<name>_present      present -> hpa exists
#     <ctrl>/hpa_<ns>_<name>_maxr         value of {.spec.maxReplicas}
#     <ctrl>/uds_<ns>           text    -> body of `get packages.uds.dev -n <ns>`
#     <ctrl>/uds_<ns>_err       present -> that get exits non-zero (probe error)
#     <ctrl>/vs_<ns>            text    -> body of `get virtualservices -n <ns>`
#     <ctrl>/vs_<ns>_err        present -> that get exits non-zero
#     every `kubectl patch ...` appends "<ns>/<res>/<name>" to <ctrl>/patches
#   helm:
#     <ctrl>/helm_absent        present -> `helm list -A` exits non-zero
#     <ctrl>/helm_list          text    -> stdout of `helm list -A`

make_k8s_stubs() {
  local bin="$1"
  mkdir -p "$bin"

  cat > "$bin/k3d" <<'STUB'
#!/usr/bin/env bash
CTRL="$STUB_CTRL"
case "$*" in
  "kubeconfig write"*)
    [ -f "$CTRL/k3d_absent" ] && exit 1
    echo "${CTRL}/kubeconfig"; exit 0 ;;
esac
exit 0
STUB

  cat > "$bin/helm" <<'STUB'
#!/usr/bin/env bash
CTRL="$STUB_CTRL"
case "$*" in
  "list -A"*)
    [ -f "$CTRL/helm_absent" ] && exit 1
    cat "$CTRL/helm_list" 2>/dev/null; exit 0 ;;
esac
exit 0
STUB

  cat > "$bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# Fake kubectl: parse the subset of args the box watchers use, answer from the
# control dir, and record every patch. Unknown verbs are a silent success.
CTRL="$STUB_CTRL"
ns=""; res=""; name=""; jpath=""; israw=0; ispatch=0; gotget=0; allns=0
argv=("$@"); n=${#argv[@]}; idx=0
while [ "$idx" -lt "$n" ]; do
  a="${argv[$idx]}"
  case "$a" in
    -n)     idx=$((idx+1)); ns="${argv[$idx]}" ;;
    get)    gotget=1 ;;
    patch)  ispatch=1; gotget=1 ;;
    --raw*) israw=1 ;;
    -A)     allns=1 ;;
    -o)     idx=$((idx+1)); o="${argv[$idx]}"
            case "$o" in jsonpath=*) jpath="${o#jsonpath=}" ;; esac ;;
    -*)     : ;;
    *)      if   [ "$gotget" = 1 ] && [ -z "$res" ];  then res="$a"
            elif [ "$gotget" = 1 ] && [ -z "$name" ]; then name="$a"; fi ;;
  esac
  idx=$((idx+1))
done

if [ "$israw" = 1 ]; then
  exit "$(cat "$CTRL/readyz_rc" 2>/dev/null || echo 0)"
fi

if [ "$ispatch" = 1 ]; then
  printf '%s/%s/%s\n' "$ns" "$res" "$name" >> "$CTRL/patches"
  echo "patched"; exit 0
fi

# Map the requested jsonpath field to a control-file suffix.
fkey=""
case "$jpath" in
  *maxReplicas*)   fkey="maxr" ;;
  *replicas*)      fkey="replicas" ;;
  *strategy.type*) fkey="stype" ;;
  *maxSurge*)      fkey="surge" ;;
esac

case "$res" in
  deploy|deployment|deployments|deployment.apps)
    if [ "$allns" = 1 ]; then cat "$CTRL/deploy_rows" 2>/dev/null; exit 0; fi
    if [ -n "$fkey" ]; then cat "$CTRL/deploy_${ns}_${name}_${fkey}" 2>/dev/null; exit 0; fi
    if [ -f "$CTRL/deploy_${ns}_${name}_present" ]; then exit 0; else exit 1; fi ;;
  hpa|horizontalpodautoscaler|horizontalpodautoscalers)
    if [ -n "$fkey" ]; then cat "$CTRL/hpa_${ns}_${name}_${fkey}" 2>/dev/null; exit 0; fi
    if [ -f "$CTRL/hpa_${ns}_${name}_present" ]; then exit 0; else exit 1; fi ;;
  packages.uds.dev|packages|package)
    [ -f "$CTRL/uds_${ns}_err" ] && exit 1
    cat "$CTRL/uds_${ns}" 2>/dev/null; exit 0 ;;
  virtualservices.networking.istio.io|virtualservices|virtualservice|vs)
    [ -f "$CTRL/vs_${ns}_err" ] && exit 1
    cat "$CTRL/vs_${ns}" 2>/dev/null; exit 0 ;;
esac
exit 0
STUB

  chmod +x "$bin/k3d" "$bin/helm" "$bin/kubectl"
}
