FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
ENV PYTHONUNBUFFERED=1
# `USER nobody` has no home directory by default (HOME=/nonexistent), which breaks Chroma's
# default local embedding function the moment it needs to cache its ONNX model for a QUERY
# embedding — confirmed live: "[Errno 13] Permission denied: '/nonexistent'" on every
# chroma_query call specifically (chroma_list_collections works fine since it needs no
# embedding at all, which is why this wasn't caught by earlier testing). Give it an explicit,
# writable HOME instead — matches chroma-ui's own HOME (see that Dockerfile) so the shared
# chroma_onnx_cache volume (compose.yaml) actually lands in the same place for both.
ENV HOME=/home/chroma
RUN mkdir -p "$HOME" && chmod 777 "$HOME"
USER nobody
CMD ["python", "server.py"]
