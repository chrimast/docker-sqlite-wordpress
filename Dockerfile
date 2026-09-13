FROM wordpress:php8.1-apache
LABEL org.opencontainers.image.authors="soulteary@gmail.com"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV WORDPRESS_PREPARE_DIR=/usr/src/wordpress
ENV SQLITE_DATABASE_INTEGRATION_VERSION=${SQLITE_DATABASE_INTEGRATION_VERSION}

# details: https://soulteary.com/2024/04/21/wordpress-sqlite-docker-image-packaging-details.html
COPY --from=ext-builder /plugin ${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-database-integration

# Companion must-use plugin: normalizes SELECT column-name casing (e.g. "P.id")
# that SQLite otherwise returns as the declared column name (e.g. "ID"). Files
# in the mu-plugins root are auto-loaded and cannot be deactivated.
COPY plugins/sqlite-select-id-key-fix.php ${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-select-id-key-fix.php

# Companion must-use plugin: read-only diagnostics page under the Tools menu
# that surfaces the native parser / SQLite / environment / integration state.
# Auto-loaded from the mu-plugins root and cannot be deactivated.
COPY plugins/sqlite-diagnostics.php ${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-diagnostics.php

# Optional SMTP transport with an administrator settings page and per-field
# environment overrides. It is disabled by default and includes OwlMail-safe
# defaults for the optional Compose integration.
COPY plugins/sqlite-wordpress-smtp.php ${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-wordpress-smtp.php

# Optional, disabled-by-default server performance display. Administrators or
# an exact boolean environment override can expose generation time and PHP
# memory usage in the toolbar and public page footer.
COPY plugins/sqlite-wordpress-performance.php ${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-wordpress-performance.php

# WordPress's official entrypoint intentionally leaves an initialized docroot
# untouched. Bundle the exact pinned core as a no-content archive and let this
# MU plugin replace only matching WordPress.org update offers with a verified
# temporary copy of that local package.
COPY --from=ext-builder /wordpress-core-no-content.zip /usr/src/wordpress-upgrades/wordpress-${WORDPRESS_VERSION}-no-content.zip
COPY --from=ext-builder /wordpress-core-no-content.zip.sha256 /usr/src/wordpress-upgrades/wordpress-${WORDPRESS_VERSION}-no-content.zip.sha256
COPY plugins/sqlite-local-core-update.php ${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-local-core-update.php

# mu-plugins only auto-loads .php files in the mu-plugins root; it does NOT
# recurse into subdirectories, so the plugin's own
# sqlite-database-integration/load.php is never executed on its own. This
# root-level loader requires that load.php to mount its admin UI (the SQLite
# health-check / settings page under Settings). The SQLite driver itself loads
# via wp-content/db.php and does not depend on this loader.
COPY plugins/sqlite-database-integration-loader.php ${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-database-integration-loader.php

# Disabled-by-default emergency endpoint for repairing the database-backed
# WordPress Address (`siteurl`) and Site Address (`home`) after a domain change.
# It returns 404 unless explicitly enabled with one strong credential.
COPY tool-update-site-url.php ${WORDPRESS_PREPARE_DIR}/tool-update-site-url.php

# Disabled-by-default emergency endpoint for selecting a local WordPress user
# and resetting its password. It has its own enable switch, credential, and
# persistent one-shot authorization state.
COPY tool-reset-user-password.php ${WORDPRESS_PREPARE_DIR}/tool-reset-user-password.php

# Self-healing entrypoint: the stock WordPress entrypoint only seeds a mounted
# volume when it is empty, so an already-initialized/old volume never receives
# the SQLite drop-in (wp-content/db.php) and WordPress falls back to MySQL
# ("Error establishing a database connection"). This wrapper reconciles the
# SQLite drop-in + mu-plugins into the live docroot on every start.
COPY docker-entrypoint-sqlite.sh /usr/local/bin/docker-entrypoint-sqlite.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-sqlite.sh

RUN mv "${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-database-integration/db.copy" "${WORDPRESS_PREPARE_DIR}/wp-content/db.php" && \
    sed -i 's#{SQLITE_IMPLEMENTATION_FOLDER_PATH}#/var/www/html/wp-content/mu-plugins/sqlite-database-integration#' "${WORDPRESS_PREPARE_DIR}/wp-content/db.php" && \
    sed -i 's#{SQLITE_PLUGIN}#sqlite-database-integration/load.php#' "${WORDPRESS_PREPARE_DIR}/wp-content/db.php" && \
    mkdir -p "${WORDPRESS_PREPARE_DIR}/wp-content/database" \
             "${WORDPRESS_PREPARE_DIR}/wp-content/plugins" \
             "${WORDPRESS_PREPARE_DIR}/wp-content/themes" \
             "${WORDPRESS_PREPARE_DIR}/wp-content/uploads" \
             "${WORDPRESS_PREPARE_DIR}/wp-content/upgrade" && \
    touch "${WORDPRESS_PREPARE_DIR}/wp-content/database/.ht.sqlite" && \
    chown -R www-data:www-data "${WORDPRESS_PREPARE_DIR}/wp-content" && \
    find "${WORDPRESS_PREPARE_DIR}/wp-content" -type d -exec chmod 755 {} + && \
    chmod 640 "${WORDPRESS_PREPARE_DIR}/wp-content/database/.ht.sqlite" && \
    core_package="/usr/src/wordpress-upgrades/wordpress-${WORDPRESS_VERSION}-no-content.zip" && \
    core_package_sha256="$(cat "${core_package}.sha256")" && \
    test "$(printf '%s' "${core_package_sha256}" | wc -c)" -eq 64 && \
    sed -i \
      -e "s/{WORDPRESS_VERSION}/${WORDPRESS_VERSION}/g" \
      -e "s/{WORDPRESS_CORE_PACKAGE_SHA256}/${core_package_sha256}/g" \
      "${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-local-core-update.php" && \
    ! grep -Eq '\{WORDPRESS_(VERSION|CORE_PACKAGE_SHA256)\}' \
      "${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-local-core-update.php" && \
    chown -R root:root /usr/src/wordpress-upgrades && \
    chmod 0555 /usr/src/wordpress-upgrades && \
    chmod 0444 /usr/src/wordpress-upgrades/*

# Fail the build (instead of silently shipping a broken drop-in) if the upstream
# layout changes: the SQLite loader must be present, its `../database` sibling
# (a symlink upstream) must be materialized, the query-monitor integration
# boot.php required by wp-includes/sqlite/db.php must exist, the generated
# db.php must define SQLITE_DB_DROPIN_VERSION (so constants.php selects the
# sqlite engine and activate.php never overwrites it), and the db.php
# placeholder must have been replaced so it never falls back to the wrong
# `plugins/` path (see #478).
RUN test -f "${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-database-integration/wp-includes/sqlite/db.php" && \
    test -f "${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-database-integration/wp-includes/database/load.php" && \
    test -f "${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-database-integration/integrations/query-monitor/boot.php" && \
    test -f "${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-local-core-update.php" && \
    test -f "${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-wordpress-performance.php" && \
    test -f "${WORDPRESS_PREPARE_DIR}/wp-content/mu-plugins/sqlite-wordpress-smtp.php" && \
    test -s "/usr/src/wordpress-upgrades/wordpress-${WORDPRESS_VERSION}-no-content.zip" && \
    test -f "${WORDPRESS_PREPARE_DIR}/tool-update-site-url.php" && \
    test -f "${WORDPRESS_PREPARE_DIR}/tool-reset-user-password.php" && \
    grep -q 'SQLITE_DB_DROPIN_VERSION' "${WORDPRESS_PREPARE_DIR}/wp-content/db.php" && \
    ! grep -q '{SQLITE_IMPLEMENTATION_FOLDER_PATH}' "${WORDPRESS_PREPARE_DIR}/wp-content/db.php"

# Enable the native MySQL parser extension when it was actually built.
# On platforms where the build was skipped, the copied file is empty (a
# placeholder), so we only register the extension when it contains a real .so.
COPY --from=ext-builder /libwp_mysql_parser.so /usr/local/lib/php/extensions/wp_mysql_parser.so
RUN if [ -s /usr/local/lib/php/extensions/wp_mysql_parser.so ]; then \
      echo "extension=/usr/local/lib/php/extensions/wp_mysql_parser.so" > /usr/local/etc/php/conf.d/wp_mysql_parser.ini ; \
    else \
      echo "Native wp_mysql_parser extension not built for this platform; using PHP fallback." && \
      rm -f /usr/local/lib/php/extensions/wp_mysql_parser.so ; \
    fi

# Wrap the stock entrypoint so the SQLite drop-in is (re)installed on any volume
# state; CMD stays the base image's apache2-foreground.
ENTRYPOINT ["docker-entrypoint-sqlite.sh"]
CMD ["apache2-foreground"]
