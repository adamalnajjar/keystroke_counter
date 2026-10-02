FROM python:3.13-slim
WORKDIR /app
COPY app.py .
# Run as the Pi's admin user (uid 1000) so ./data stays owned by admin on the host.
USER 1000:1000
ENV PYTHONUNBUFFERED=1
CMD ["python", "app.py"]
