require "net/http"
require "uri"
require "cgi"

module PreviewEnrichment
  module Providers
    class RepositorySearchBase < Base
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15
      MAX_BODY_BYTES = 3 * 1024 * 1024

      def search
        queries.flat_map do |query|
          search_repository(query)
        rescue StandardError => error
          Rails.logger.warn(
            {
              event: "preview_enrichment_repository_search_failed",
              provider: provider_name,
              model_id: model.id,
              query: query,
              error: error.class.name,
              message: error.message
            }.to_json
          )

          []
        end
      end

      private

      def queries
        PreviewEnrichment::QueryBuilder
          .new(model)
          .queries
          .first(3)
      end

      def fetch_html(uri)
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Mozilla/5.0 MakerLibrary3D/1.0"
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

        return nil unless response.is_a?(Net::HTTPSuccess)

        body = response.body.to_s

        raise "Response too large" if body.bytesize > MAX_BODY_BYTES

        body
      end

      def normalize(text)
        CGI.unescapeHTML(text.to_s)
          .gsub(/<[^>]+>/, " ")
          .gsub(/\s+/, " ")
          .strip
      end
    end
  end
end
