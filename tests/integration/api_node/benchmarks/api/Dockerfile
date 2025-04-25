FROM justb4/jmeter

COPY hivesense_api.jmx /jmeter/hivesense_api.jmx
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

WORKDIR /test

ENTRYPOINT ["/entrypoint.sh"]