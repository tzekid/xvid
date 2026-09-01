xvid.plosca.ru {
	encode zstd gzip

	log {
		output file /var/log/caddy/xvid.access.log
		format filter {
			request>uri regexp `\?.*$` ""
			request>headers>Referer delete
			wrap json
		}
	}

	@healthAlias path /health
	rewrite @healthAlias /healthz

	reverse_proxy 127.0.0.1:8090 {
		flush_interval -1
	}
}
