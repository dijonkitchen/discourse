# frozen_string_literal: true

# we need to require the rails_helper from core to load the Rails environment
require_relative "../../spec/rails_helper"

require_relative "../lib/migrations"
Migrations.configure_zeitwerk

require "rspec-multi-mock"

RSpec.configure { |config| config.mock_with MultiMock::Adapter.for(:rspec, :mocha) }
