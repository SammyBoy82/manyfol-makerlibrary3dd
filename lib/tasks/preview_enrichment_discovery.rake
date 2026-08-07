namespace :preview_enrichment do
  desc "Discover preview image candidates for exactly one model: MODEL_ID=123"
  task discover_one: :environment do
    model_id = ENV["MODEL_ID"]

    abort "ERROR: MODEL_ID is required" if model_id.blank?

    model = Model.find_by(id: model_id)

    abort "ERROR: Model #{model_id} not found" unless model

    puts "========================================"
    puts "MakerLibrary3D Preview Enrichment"
    puts "========================================"
    puts "Model ID:   #{model.id}"
    puts "Name:       #{model.name}"
    puts "Path:       #{model.path}"
    puts "Images:     #{model.image_files.count}"
    puts "3D files:   #{model.three_d_files.count}"
    puts "----------------------------------------"

    result = PreviewEnrichment::Runner.new(model).call

    puts "Eligible:   #{result[:eligible]}"
    puts "Reason:     #{result[:reason]}"
    puts "Discovered: #{result[:discovered]}"
    puts "Persisted:  #{result[:persisted]}"

    Array(result[:candidates]).each do |candidate|
      puts
      puts "Candidate ##{candidate.id}"
      puts "Provider:   #{candidate.provider}"
      puts "Confidence: #{candidate.confidence}"
      puts "Source:     #{candidate.source_page_url}"
      puts "Image:      #{candidate.image_url}"
      puts "Status:     #{candidate.status}"
    end

    puts "========================================"
  end
end
