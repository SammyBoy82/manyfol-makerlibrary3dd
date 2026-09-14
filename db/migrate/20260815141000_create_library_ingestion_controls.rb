class CreateLibraryIngestionControls < ActiveRecord::Migration[8.0]
  def change
    create_table :library_ingestion_controls do |t|
      t.boolean :paused,
        null: false,
        default: false

      t.datetime :last_run_at
      t.datetime :last_success_at

      t.text :last_error

      t.timestamps
    end

    add_column :libraries,
      :ingestion_enabled,
      :boolean,
      null: false,
      default: true

    add_index :libraries,
      :ingestion_enabled
  end
end
