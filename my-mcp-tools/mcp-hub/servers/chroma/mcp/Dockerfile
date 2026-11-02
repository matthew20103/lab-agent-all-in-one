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
# Pre-create the FULL path the embedding function actually writes into (not just $HOME) —
# confirmed live that chmod 777 on $HOME alone wasn't enough: whichever of chroma-ui/chroma-mcp
# populates the shared chroma_onnx_cache volume first does so as its own container's default
# user, and the resulting .cache subdirectory inherited THAT user's restrictive default perms
# ("Permission denied" on .cache/chroma/onnx_models specifically, one level deeper than $HOME
# itself). -R makes every level nobody might need to create a new entry under actually writable.
RUN mkdir -p "$HOME/.cache/chroma" && chmod -R 777 "$HOME"
USER nobody
CMD ["python", "server.py"]
