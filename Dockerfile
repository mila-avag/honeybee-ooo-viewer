FROM python:3.12-slim

WORKDIR /app
COPY honeybee_viewer_server.py index.html ./
COPY sql ./sql

ENV HOST=0.0.0.0
ENV PORT=8080
EXPOSE 8080

CMD ["python3", "honeybee_viewer_server.py"]
