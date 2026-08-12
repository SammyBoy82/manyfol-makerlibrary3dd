class AddStorefrontPublishedToModelCommercialMetadata < ActiveRecord::Migration[8.0]
  def change
    add_column :model_commercial_metadata, :storefront_published, :boolean, null: false, default: false
    add_index :model_commercial_metadata, :storefront_published
  end
end
