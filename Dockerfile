RUN mkdir -p /app/pkg /app/code
WORKDIR /app/code

RUN apt-get update && \
    apt-get install -y make gcc g++ libpq-dev zlib1g-dev rbenv brotli advancecomp jhead jpegoptim libjpeg-turbo-progs optipng pngquant gifsicle && \
    rm -r /var/cache/apt /var/lib/apt/lists

# note that changing ruby version means we have to recompile plugins
RUN echo 'gem: --no-document' >> /usr/local/etc/gemrc && \
    git clone https://github.com/sstephenson/ruby-build.git && \
    cd ruby-build && ./install.sh && cd .. && rm -rf ruby-build && \
    (ruby-build 2.7.2 /usr/local)

RUN gem install bundler

ENV RAILS_ENV production

ARG VERSION=3.0.0

RUN curl -L https://github.com/discourse/discourse/archive/v${VERSION}.tar.gz | tar -xz --strip-components 1 -f - && \
    bundle install --deployment --without test development && \
    chown -R root:root /app/code

# svgo required for image optimization
RUN npm install -g svgo terser

# for yaml-override
RUN cd /app/pkg && npm install js-yaml@3.13.1 lodash@4.17.15

# the code detects these values from a git repo otherwise
RUN echo -e "\$git_version='${VERSION}'\n\$full_version='${VERSION}'\n\$last_commit_date=DateTime.strptime('$(date +%s)','%s')" > /app/code/config/version.rb

# fixup dependency issue with uri version mismatch
RUN sed -e '/uri (0.11.0)/d' -e '/uri$/d' -i /app/code/Gemfile.lock

# -0 sets the separator to null (instead of newline). /s will make '.' match newline. .*? means non-greedy
RUN mv /app/code/config/site_settings.yml /app/code/config/site_settings.yml.default && \
    ln -s /run/discourse/site_settings.yml /app/code/config/site_settings.yml && \
    perl -i -0p -e 's/force_https:.*?default: false/force_https:\n    default: true/ms;' /app/code/config/site_settings.yml.default

# public/ - directory has files that don't change
#   assets/ - generated assets
# plugins/ - plugin code
# app/assets - app assets
#   javascripts/ - for some reason a plugin on activate will write into plugins/ (839916aa490 in discourse)
RUN ln -sf /run/discourse/discourse.conf /app/code/config/discourse.conf && \
    rm -rf /app/code/log && ln -sf /run/discourse/log /app/code/log && \
    mv /app/code/public /app/code/public.original && ln -s /run/discourse/public /app/code/public && \
    mv /app/code/plugins /app/code/plugins.original && ln -s /app/data/plugins /app/code/plugins && \
    ln -s /run/discourse/assets_js_plugins /app/code/app/assets/javascripts/plugins && \
    ln -s /run/discourse/tmp /app/code/tmp && \
    rm -rf /root/.gem && ln -s /tmp/gemcache /root/.gem && chown -R root:root /root/.gem && \
    ln -sf /run/.irb_history /root/.irb_history

# configure nginx
COPY nginx_readonlyrootfs.conf /etc/nginx/conf.d/readonlyrootfs.conf
RUN rm /etc/nginx/sites-enabled/* && \
    sed -e 's/client_max_body_size .*/client_max_body_size 200m;/g' /app/code/config/nginx.sample.conf > /etc/nginx/sites-available/discourse && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log && \
    ln -s /etc/nginx/sites-available/discourse /etc/nginx/sites-enabled/discourse

# https://perldoc.perl.org/perlre.html#Modifiers
RUN perl -i -0p -e 's/upstream discourse \{.*?\}/upstream discourse { server 127.0.0.1:3000; }/ms;' \
    -e 's,.*access_log.*,access_log /dev/stdout;,;' \
    -e 's,.*error_log.*,error_log /dev/stderr info;,;' \
    -e 's/server_name.*/server_name _;/g;' \
    -e 's,/var/www/discourse,/app/code,g;' \
    -e 's,/var/nginx,/run/nginx,g;' \
    -e 's,brotli_static on,# brotli_static on,g;' \
    /etc/nginx/sites-available/discourse

# add supervisor configs
ADD supervisor/* /etc/supervisor/conf.d/
RUN ln -sf /run/discourse/supervisord.log /var/log/supervisor/supervisord.log

ARG MAXMIND_LICENSE_KEY
RUN cd /app/code/vendor/data && \
    curl "https://download.maxmind.com/app/geoip_download?license_key=${MAXMIND_LICENSE_KEY}&edition_id=GeoLite2-City&suffix=tar.gz" | tar zxvf - --strip-components 1 --wildcards GeoLite2-City_*/GeoLite2-City.mmdb && \
    curl "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-ASN&license_key=${MAXMIND_LICENSE_KEY}&suffix=tar.gz" | tar zxvf - --strip-components 1 --wildcards GeoLite2-ASN_*/GeoLite2-ASN.mmdb

COPY start.sh yaml-override.js /app/pkg/

CMD [ "/app/pkg/start.sh" ]
