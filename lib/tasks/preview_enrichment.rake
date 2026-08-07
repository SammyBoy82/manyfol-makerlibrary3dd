namespace :preview_enrichment do
  desc "Report models that have 3D files but no real preview images"
  task inventory: :environment do
    total = 0
    eligible = 0

    Model.find_each do |model|
      total += 1

      result = PreviewEnrichment::Eligibility.new(model)

      next unless result.eligible?

      eligible += 1

      puts [
        model.id,
        model.name,
        model.path
      ].join("\t")
    end

    puts
    puts "======================================"
    puts "Preview Enrichment Inventory"
    puts "======================================"
    puts "Models scanned:            #{total}"
    puts "Need real preview images:  #{eligible}"
    puts "Already OK / excluded:     #{total - eligible}"
    puts "======================================"
  end
end
