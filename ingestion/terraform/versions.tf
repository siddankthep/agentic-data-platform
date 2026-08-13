terraform {
  # `moved` blocks and the 1.x provider's generic resources both want >= 1.8.
  required_version = ">= 1.8"

  required_providers {
    airbyte = {
      source = "airbytehq/airbyte"
      # 1.1 removed the typed per-connector resources (airbyte_source_stripe et
      # al) in favour of generic airbyte_source / airbyte_destination taking a
      # JSON configuration blob. Everything here is written against that shape.
      version = "~> 1.3"
    }
  }
}
