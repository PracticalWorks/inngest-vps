FROM inngest/inngest:v1.27.0

COPY inngest.yaml /etc/inngest/inngest.yaml

ENTRYPOINT ["inngest"]
CMD ["start", "--config", "/etc/inngest/inngest.yaml"]
