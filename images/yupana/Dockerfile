# Copyright 2026 SZL Holdings — SPDX-License-Identifier: Apache-2.0
# yupana UDS runtime image — k8s/Zarf target.
# CANONICAL IN-REPO SOURCE: the yupana GitHub source repo is deleted (404); this
# directory is now the authoritative, rebuildable source for the yupana image.
# Fixes vs the legacy HF-Space image (which ran /home/user/app/app.py as a
# mismatched user -> EACCES): runs as uid 65532 (matches deployment runAsUser),
# app at /app/serve.py (world-readable), serves on 7860 (matches the Deployment
# containerPort, Service targetPort, and the UDS mesh allow/expose rules).
FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PORT=7860
WORKDIR /app
RUN pip install --no-cache-dir "fastapi==0.111.0" "uvicorn==0.30.1"
COPY serve.py ./serve.py
EXPOSE 7860
RUN useradd -u 65532 -m yupana
USER 65532
HEALTHCHECK --interval=15s --timeout=3s --retries=5 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:7860/api/yupana/healthz').status==200 else 1)"
CMD ["uvicorn", "serve:app", "--host", "0.0.0.0", "--port", "7860"]
