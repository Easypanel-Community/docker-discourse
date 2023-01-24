#!/bin/bash

set -eu

# do not create public directory here, since code below depends on it
echo "==> Creating directories"
mkdir -p /run/discourse/log /run/discourse/tmp /run/nginx/cache /app/data/uploads /app/data/plugins /tmp/gemcache /run/discourse/assets_js_plugins

echo "==> Configuring discourse"
sed -e "s/db_host.*=.*/db_host = $POSTGRES_SQL_HOST/" \
    -e "s/db_port.*=.*/db_port = $POSTGRES_SQL_PORT/" \
    -e "s/db_name.*=.*/db_name = $POSTGRES_SQL_DATABASE/" \
    -e "s/db_username.*=.*/db_username = $POSTGRES_SQL_USERNAME}/" \
    -e "s/db_password.*=.*/db_password = $POSTGRES_SQL_PASSWORD}/" \
    -e "s/smtp_address.*=.*/smtp_address = $MAIL_SMTP_SERVER}/" \
    -e "s/smtp_port.*=.*/smtp_port = $MAIL_SMTP_PORT/" \
    -e "s/smtp_domain.*=.*/smtp_domain = $MAIL_DOMAIN/" \
    -e "s/smtp_user_name.*=.*/smtp_user_name = $MAIL_SMTP_USERNAME/" \
    -e "s/smtp_password.*=.*/smtp_password = $MAIL_SMTP_PASSWORD/" \
    -e "s/hostname.*=.*/hostname = $APP_DOMAIN/" \
    -e "s/redis_host.*=.*/redis_host= $REDIS_HOST/" \
    -e "s/redis_port*=.*/redis_port = $REDIS_PORT/" \
    -e "s/redis_password.*=.*/redis_password = $REDIS_PASSWORD/" \
    -e "s/new_version_emails.*=.*/new_version_emails = false/" \
    -e "s/serve_static_assets.*=.*/serve_static_assets = true/" \
    -e "s/developer_emails.*=.*/developer_emails = test@easypanel.io/" \
    -e "s/refresh_maxmind_db_during_precompile_days.*=.*/refresh_maxmind_db_during_precompile_days = 0/" \
    /app/code/config/discourse_defaults.conf > /run/discourse/discourse.conf

# public/uploads contains the uploaded images
if [[ ! -d /run/discourse/public ]]; then
    echo "==> Populate public directory"
    mkdir /run/discourse/public
    cp -r /app/code/public.original/* /run/discourse/public
    unlink /run/discourse/public/uploads 2>/dev/null || true
    ln -sf /app/data/uploads /run/discourse/public/uploads
fi

# plugins
echo "==> Creating symlinks for built-in plugins"
for plugin in `find "/app/code/plugins.original"/* -maxdepth 0 -type d -printf "%f\n"`; do
    rm -f /app/data/plugins/${plugin}
    ln -sf /app/code/plugins.original/${plugin} /app/data/plugins/${plugin}
done

# create dummy settings file
if [[ ! -f /app/data/site_settings.yml ]]; then
    echo "# Add additional customizations in this file" > /app/data/site_settings.yml
fi

# merge user yaml file (yaml does not allow key re-declaration)
cp /app/code/config/site_settings.yml.default /run/discourse/site_settings.yml

/app/pkg/yaml-override.js /run/discourse/site_settings.yml /app/data/site_settings.yml

echo "==> Changing permissions"
chown -R root:root /run/discourse /app/data /tmp/gemcache

# PATH is set so that it can find svgo
# this also activates plugins which generates assets into app/assets/javascripts/plugins
echo "==> Migrating database"
sudo -E -u bundle exec rake db:migrate

# have to do this for domain change. this puts assets in public/assets
# Use the nodejs version of uglifyjs since the gem is bad - https://meta.discourse.org/t/uglifier-error-during-assets-precompile/96970
# newer releases have a SKIP_DB_AND_REDIS=1 which we can use to precompile assets in docker?
if ! ls /app/code/public/assets/application-*.js >/dev/null 2>&1; then
    echo "==> Pre-compiling assets"
    sudo -E -u bundle exec rake assets:precompile
else
    echo "==> Skip building assets (already built)"
fi

if [[ ! -f /app/data/.admin_setup ]]; then
    # The email is carefully chosen so that discourse always auto-picks root as the username
    echo "==> Creating administrator with username root"
    (sleep 5; echo -e "root@easypanel.io\nchangeme123\nchangeme123"; sleep 5; echo "Y") | sudo -E -u bundle exec rake admin:create
    sudo -u touch /app/data/.admin_setup
fi

# https://meta.discourse.org/t/troubleshooting-email-on-a-new-discourse-install/16326/2
echo "==> Fixing notification email"
sudo -E -u cloudron bundle exec script/rails runner "SiteSetting.notification_email = '${CLOUDRON_MAIL_FROM}'"

echo "==> Starting discourse"
exec /usr/bin/supervisord --configuration /etc/supervisor/supervisord.conf --nodaemon -i Discourse
