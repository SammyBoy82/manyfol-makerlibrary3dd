class LibraryIngestion::ProcessJob < ApplicationJob
  queue_as :default

  def perform(ingest_id)
    ingest = LibraryIngest.find(ingest_id)

    return if ingest.completed?
    return if ingest.processing?

    LibraryIngestion::Processor.new(ingest).process
  end
end
