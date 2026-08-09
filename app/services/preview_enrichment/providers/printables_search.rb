require "net/http"
require "uri"
require "json"
require "cgi"

module PreviewEnrichment
  module Providers
    class PrintablesSearch < Base
      BASE_URL = "https://www.printables.com"
      MEDIA_URL = "https://media.printables.com"
      MAX_RESULTS = 10
      MAX_QUERIES = 3

      def search
        candidates = search_queries.flat_map do |query|
          search_printables(query)
        rescue StandardError => error
          Rails.logger.warn(
            {
              event: "preview_enrichment_printables_search_failed",
              provider: "printables",
              model_id: model.id,
              query: query,
              error: error.class.name,
              message: error.message
            }.to_json
          )

          []
        end

        candidates
          .compact
          .uniq { |candidate| candidate.source_page_url }
          .sort_by { |candidate| -candidate.confidence.to_i }
          .first(MAX_RESULTS)
      end

      private

      def search_queries
        PreviewEnrichment::QueryBuilder
          .new(model)
          .queries
          .first(MAX_QUERIES)
          .map { |query| clean_query(query) }
          .reject(&:blank?)
          .uniq
      end

      def clean_query(query)
        query.to_s
          .gsub('"', "")
          .gsub(/\b3D printable model\b/i, "")
          .gsub(/\bSTL\b/i, "")
          .gsub(/\s+/, " ")
          .strip
      end

      def search_printables(query)
        uri = URI("#{BASE_URL}/search/models")
        uri.query = URI.encode_www_form(q: query)

        html = fetch_html(uri)

        items = extract_search_items(html)

        items.filter_map do |item|
          build_candidate(item, query)
        end
      end

      def fetch_html(uri)
        request = Net::HTTP::Get.new(uri)

        request["User-Agent"] =
          "Mozilla/5.0 (compatible; MakerLibrary3D/1.0)"

        request["Accept"] =
          "text/html,application/xhtml+xml"

        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: true,
          open_timeout: 8,
          read_timeout: 20
        ) do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise "Printables HTTP #{response.code}"
        end

        response.body.to_s
      end

      def extract_search_items(html)
        responses = html.scan(
          /<script[^>]+type=["']application\/json["'][^>]+data-sveltekit-fetched[^>]*>(.*?)<\/script>/mi
        ).flatten

        responses.each do |raw|
          begin
            wrapper = JSON.parse(
              CGI.unescapeHTML(raw)
            )

            body = wrapper["body"]
            next unless body.present?

            payload = JSON.parse(body)

            items = payload.dig(
              "data",
              "result",
              "items"
            )

            next unless items.is_a?(Array)
            next if items.empty?

            # Search results contain PrintType objects.
            if items.any? { |item| item["__typename"] == "PrintType" }
              return items
            end
          rescue JSON::ParserError
            next
          end
        end

        []
      end

      def build_candidate(item, query)
        id = item["id"].to_s
        slug = item["slug"].to_s
        title = item["name"].to_s.strip

        return nil if id.blank?
        return nil if slug.blank?
        return nil if title.blank?

        creator =
          item.dig("user", "handle").presence ||
          item.dig("user", "publicUsername").presence

        page_url =
          "#{BASE_URL}/model/#{id}-#{slug}"

        Candidate.new(
          provider: "printables",
          source_page_url: page_url,
          image_url: image_url_for(item),
          title: title,
          creator: creator,
          license: nil,
          confidence: confidence_for(
            title: title,
            creator: creator,
            query: query
          ),
          match_method: "printables_sveltekit_search",
          metadata: {
            query: query,
            printables_id: id,
            slug: slug,
            downloads: item["downloadCount"],
            likes: item["likesCount"],
            rating: item["ratingAvg"],
            image_count: item["imagesCount"],
            nsfw: item["nsfw"],
            ai_generated: item["aiGenerated"],
            political_content: item["politicalContent"],
            price: item["price"],
            price_before_sale: item["priceBeforeSale"],
            category: category_path(item),
            creator_handle: item.dig("user", "handle"),
            creator_name: item.dig("user", "publicUsername")
          }
        )
      end

      def image_url_for(item)
        path = item.dig("image", "filePath").to_s

        return nil if path.blank?

        "#{MEDIA_URL}/#{path}"
      end

      def category_path(item)
        Array(item.dig("category", "path"))
          .map { |entry| entry["name"] }
          .compact
      end

      def confidence_for(title:, creator:, query:)
        model_text = normalized(model.name)
        title_text = normalized(title)
        query_text = normalized(query)

        score = 35

        if title_text == model_text
          score = 95
        elsif title_text == query_text
          score = 92
        else
          model_words = significant_words(model_text)
          title_words = significant_words(title_text)

          overlap = model_words & title_words

          if model_words.any?
            ratio = overlap.length.to_f / model_words.length
            score += (ratio * 50).round
          end

          if title_text.include?(model_text) ||
             model_text.include?(title_text)
            score += 15
          end
        end

        creator_text = normalized(creator)

        if creator_hints.any? do |hint|
          creator_text == normalized(hint)
        end
          score += 15
        end

        [[score, 40].max, 99].min
      end

      def creator_hints
        @creator_hints ||= begin
          texts = [
            model.name,
            model.path,
            *model.model_files.map(&:filename)
          ].compact.map(&:to_s)

          texts
            .flat_map do |text|
              text.scan(/@([A-Za-z0-9_.-]+)/).flatten
            end
            .map do |value|
              value.gsub(/\.(stl|3mf|obj)\z/i, "")
            end
            .map(&:strip)
            .reject(&:blank?)
            .uniq
            .first(3)
        end
      end

      def significant_words(text)
        normalized(text)
          .scan(/[a-z0-9]+/)
          .reject { |word| word.length < 3 }
          .reject do |word|
            %w[
              stl
              model
              printable
              presupported
              supported
              version
              file
              files
            ].include?(word)
          end
          .uniq
      end

      def normalized(value)
        value.to_s
          .downcase
          .gsub(/[^a-z0-9]+/, " ")
          .gsub(/\s+/, " ")
          .strip
      end
    end
  end
end
