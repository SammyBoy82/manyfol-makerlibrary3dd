module PreviewEnrichment
  module Providers
    class Base
      Candidate = Data.define(
        :provider,
        :source_page_url,
        :image_url,
        :title,
        :creator,
        :license,
        :confidence,
        :match_method,
        :metadata
      )

      def initialize(model)
        @model = model
      end

      def search
        raise NotImplementedError
      end

      private

      attr_reader :model
    end
  end
end
