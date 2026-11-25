FROM node:22-bookworm-slim

ENV CHROME_PATH=/usr/bin/chromium \
    WCAG_CHECK_HOME=/opt/wcag22-check/cache \
    TZ=Asia/Taipei \
    XDG_CONFIG_HOME=/tmp/.chromium-config \
    XDG_CACHE_HOME=/tmp/.chromium-cache

RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium \
        fonts-noto-cjk \
        fonts-liberation \
        ca-certificates \
        tzdata \
    && ln -snf /usr/share/zoneinfo/Asia/Taipei /etc/localtime \
    && echo "Asia/Taipei" > /etc/timezone \
    && rm -rf /var/lib/apt/lists/*

# 預先安裝相依套件至 WCAG_CHECK_HOME，避免容器啟動時重新下載
RUN mkdir -p "$WCAG_CHECK_HOME" \
    && echo '{"name":"wcag22-check-deps","private":true}' > "$WCAG_CHECK_HOME/package.json" \
    && cd "$WCAG_CHECK_HOME" \
    && PUPPETEER_SKIP_DOWNLOAD=1 npm install --no-audit --no-fund --loglevel=error \
        puppeteer-core @axe-core/puppeteer axe-core@4 \
    && npm cache clean --force \
    && chmod 1777 "$WCAG_CHECK_HOME"

COPY --chmod=755 wcag22-check.sh /usr/local/bin/wcag22-check.sh
COPY --chmod=755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN mkdir -p /output && chmod 1777 /output
WORKDIR /output

USER node

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["--help"]
