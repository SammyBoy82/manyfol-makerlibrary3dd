class CreateModelCommercialMetadata < ActiveRecord::Migration[8.0]
  def change
    create_table :model_commercial_metadata do |t|
      t.references :model, null: false, foreign_key: {on_delete: :cascade}, index: {unique: true}
      t.string :sku
      t.boolean :member_download_enabled, null: false, default: true
      t.boolean :digital_sale_enabled, null: false, default: false
      t.boolean :physical_sale_enabled, null: false, default: false
      t.boolean :custom_quote_enabled, null: false, default: false
      t.integer :digital_price_cents
      t.integer :physical_from_price_cents
      t.string :currency, null: false, default: "AUD"
      t.boolean :featured, null: false, default: false
      t.integer :lead_time_days
      t.text :commercial_notes
      t.timestamps
    end

    add_index :model_commercial_metadata, :sku, unique: true, where: "sku IS NOT NULL"
    add_index :model_commercial_metadata, :featured
  end
end
