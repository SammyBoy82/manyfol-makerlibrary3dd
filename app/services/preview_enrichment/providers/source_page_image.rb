require "net/http"
require "cgi"
require "uri"

module PreviewEnrichment
  module Providers
    class SourcePageImage < Base
      ALLOWED_HOSTS = %w[
        thingiverse.com
        www.thingiverse.com
        cults3d.com
        www.cults3d.com
        myminifactory.com
        www.myminifactory.com
        makerworld.com
        www.makerworld.com
        printables.com
        www.printables.com
        thangs.com
        www.thangs.com
      ].freeze

      MAX_REDIRECTS = 3
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 10
      MAX_BODY_BYTES = 2 * 1024 * 1024

      def search
        trusted_links.filter_map do |url|
          candidate_from_page(url)
        rescue StandardError => error
          Rails.logger.warn(
            {
              event: "preview_enrichment_source_page_failed",
              model_id: model.id,
              url: url,
              error: error.class.name,
              message: error.message
            }.to_json
          )

          nil
        end
      end

      private

      def trusted_links
        model.links.map(&:url).select do |url|
          uri = URI.parse(url)
          uri.is_a?(URI::HTTP) && ALLOWED_HOSTS.include?(uri.host&.downcase)
        rescue URI::InvalidURIError
          false
        end
      end

      def candidate_from_page(url)
        response, final_uri = fetch(url)

        return unless response.is_a?(Net::HTTPSuccess)

        html = response.body.to_s

        image_url =
          meta_content(html, "property", "og:image") ||
          meta_content(html, "name", "twitter:image")

        return if image_url.blank?

        absolute_image_url = URI.join(final_uri.to_s, image_url).to_s

        Candidate.new(
          provider: provider_for(final_uri.host),
          source_page_url: final_uri.to_s,
          image_url: absolute_image_url,
          title: meta_content(html, "property", "og:title") || model.name,
          creator: model.creator&.name,
          license: nil,
          confidence: 95,
          match_method: "trusted_source_page_metadata",
          metadata: {
            source: "open_graph",
            hostname: final_uri.host
          }
        )
      end

      def fetch(url, redirects = 0)
        raise "Too many redirects" if redirects > MAX_REDIRECTS

        uri = URI.parse(url)

        validate_uri!(uri)

        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "MakerLibrary3D Preview Enrichment/1.0"
        request["Accept"] = "text/html,application/xhtml+xml"

        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: OPEN_TIMEOUT,
          read_timeout: READ_TIMEOUT
        ) do |http|
          http.request(request)
        end

        if response.is_a?(Net::HTTPRedirection)
          location = response["location"]
          raise "Redirect missing location" if location.blank?

          next_uri = URI.join(uri.to_s, location)
          validate_uri!(next_uri)

          return fetch(next_uri.to_s, redirects + 1)
        end

        body = response.body.to_s

        raise "Response too large" if body.bytesize > MAX_BODY_BYTES

        [response, uri]
      end

      def validate_uri!(uri)
        raise "Unsupported URI scheme" unless %w[http https].include?(uri.scheme)
        raise "Untrusted host" unless ALLOWED_HOSTS.include?(uri.host&.downcase)
      end

      def meta_content(html, attribute, value)
        patterns = [
          /<meta[^>]+#{attribute}=["']#{Regexp.escape(value)}["'][^>]+content=["']([^"']+)["'][^>]*>/i,
          /<meta[^>]+content=["']([^"']+)["'][^>]+#{attribute}=["']#{Regexp.escape(value)}["'][^>]*>/i
        ]

        patterns.each do |pattern|
          match = html.match(pattern)
          return CGI.unescapeHTML(match[1]) if match
        end

        nil
      end

      def provider_for(host)
        case host&.downcase
        when "thingiverse.com", "www.thingiverse.com"
          "thingiverse"
        when "cults3d.com", "www.cults3d.com"
          "cults3d"
        when "myminifactory.com", "www.myminifactory.com"
          "myminifactory"
        when "makerworld.com", "www.makerworld.com"
          "makerworld"
        when "printables.com", "www.printables.com"
          "printables"
        when "thangs.com", "www.thangs.com"
          "thangs"
        else
          "unknown"
        end
      end
    end
  end
end
