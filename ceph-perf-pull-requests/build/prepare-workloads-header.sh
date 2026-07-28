#!/bin/bash
# Embed prepare-workloads.py into the workspace (ceph-build is not checked out on the agent).
# JJB concatenates: this header + prepare-workloads.py + footer.
cat > "${WORKSPACE}/prepare-workloads.py" <<'PY'
