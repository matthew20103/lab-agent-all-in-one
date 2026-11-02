FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY templates/ templates/
ENV PYTHONUNBUFFERED=1
# Matches chroma-mcp's HOME (see that Dockerfile) so both containers' Chroma default embedding
# function cache lands in the same place on the shared chroma_onnx_cache volume (compose.yaml).
# This container runs as root, so IT never lacks permission here — but whichever of this
# container and chroma-mcp (runs as `nobody`) populates the shared, empty volume first does so
# with ITS OWN default permissions, and chroma-mcp needs to be able to write there too
# regardless of which one goes first. chmod -R 777 here, same as chroma-mcp's Dockerfile.
ENV HOME=/home/chroma
RUN mkdir -p "$HOME/.cache/chroma" && chmod -R 777 "$HOME"
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
