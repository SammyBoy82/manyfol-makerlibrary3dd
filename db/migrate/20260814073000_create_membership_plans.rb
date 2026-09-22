class CreateMembershipPlans < ActiveRecord::Migration[8.0]
  def change
    create_table :membership_plans do |t|
      t.string :name, null: false
      t.text :description

      t.string :billing_interval,
        null: false,
        default: "month"

      t.boolean :active,
        null: false,
        default: true

      t.boolean :all_libraries,
        null: false,
        default: false

      t.string :stripe_product_id
      t.string :stripe_price_id

      t.timestamps
    end

    add_index :membership_plans, :name, unique: true
    add_index :membership_plans, :active

    create_table :membership_plan_libraries do |t|
      t.references :membership_plan,
        null: false,
        foreign_key: true

      t.references :library,
        null: false,
        foreign_key: true

      t.timestamps
    end

    add_index :membership_plan_libraries,
      [:membership_plan_id, :library_id],
      unique: true,
      name: "idx_membership_plan_library_unique"

    add_reference :users,
      :membership_plan,
      foreign_key: true,
      index: true
  end
end
