Rails.application.config.filter_parameters += [
  :account_key,
  :sas_token,
  :storage_key,
  :storage_secret
]
