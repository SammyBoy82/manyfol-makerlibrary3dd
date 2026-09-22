class AddProcessingStateToLibraryIngests < ActiveRecord::Migration[8.0]
  def change
    add_column :library_ingests,
      :processing_status,
      :string,
      null: false,
      default: "waiting"

    add_column :library_ingests,
      :processing_error,
      :text

    add_column :library_ingests,
      :processing_started_at,
      :datetime

    add_column :library_ingests,
      :ready_at,
      :datetime

    add_column :library_ingests,
      :render_jobs_count,
      :integer,
      null: false,
      default: 0

    add_index :library_ingests,
      :processing_status
  end
end
