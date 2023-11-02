# frozen_string_literal: true

class ThemeSettingsMigrationsRunner
  Migration = Struct.new(:version, :name, :original_name, :code, :theme_field_id)

  MIGRATION_ENTRY_POINT_JS = <<~JS
    const migrate = require("discourse/theme/migration")?.default;
    function main(settingsObj) {
      if (!migrate) {
        throw new Error("no_exported_migration_function");
      }
      if (typeof migrate !== "function") {
        throw new Error("default_export_is_not_a_function");
      }
      const map = new Map(Object.entries(settingsObj));
      const updatedMap = migrate(map);
      if (!updatedMap) {
        throw new Error("migration_function_no_returned_value");
      }
      if (!(updatedMap instanceof Map)) {
        throw new Error("migration_function_wrong_return_type");
      }
      return Object.fromEntries(updatedMap.entries());
    }
  JS

  private_constant :Migration, :MIGRATION_ENTRY_POINT_JS

  def self.loader_js_lib_content
    @loader_js_lib_content ||=
      File.read(
        File.join(
          Rails.root,
          "app/assets/javascripts/node_modules/loader.js/dist/loader/loader.js",
        ),
      )
  end

  def initialize(theme, limit: 100, timeout: 100, memory: 2.megabytes)
    @theme = theme
    @limit = limit
    @timeout = timeout
    @memory = memory
  end

  def run
    fields = lookup_pending_migrations_fields

    count = fields.count
    return [] if count == 0

    raise_error("themes.import_error.migrations.too_many_pending_migrations") if count > @limit

    migrations = convert_fields_to_migrations(fields)
    migrations.sort_by!(&:version)

    current_migration_version =
      @theme.theme_settings_migrations.order(version: :desc).pick(:version)
    current_migration_version ||= -Float::INFINITY

    current_settings = lookup_overriden_settings

    migrations.map do |migration|
      if migration.version <= current_migration_version
        raise_error(
          "themes.import_error.migrations.out_of_sequence",
          name: migration.original_name,
          current: current_migration_version,
        )
      end

      migrated_settings = execute(migration, current_settings)
      results = {
        version: migration.version,
        name: migration.name,
        original_name: migration.original_name,
        theme_field_id: migration.theme_field_id,
        settings_before: current_settings,
        settings_after: migrated_settings,
      }
      current_settings = migrated_settings
      current_migration_version = migration.version
      results
    rescue DiscourseJsProcessor::TranspileError => error
      raise_error(
        "themes.import_error.migrations.syntax_error",
        name: migration.original_name,
        error: error.message,
      )
    rescue MiniRacer::V8OutOfMemoryError
      raise_error(
        "themes.import_error.migrations.exceeded_memory_limit",
        name: migration.original_name,
      )
    rescue MiniRacer::ScriptTerminatedError
      raise_error("themes.import_error.migrations.timed_out", name: migration.original_name)
    rescue MiniRacer::RuntimeError => error
      message = error.message
      if message.include?("no_exported_migration_function")
        raise_error(
          "themes.import_error.migrations.no_exported_function",
          name: migration.original_name,
        )
      elsif message.include?("default_export_is_not_a_function")
        raise_error(
          "themes.import_error.migrations.default_export_not_a_function",
          name: migration.original_name,
        )
      elsif message.include?("migration_function_no_returned_value")
        raise_error(
          "themes.import_error.migrations.no_returned_value",
          name: migration.original_name,
        )
      elsif message.include?("migration_function_wrong_return_type")
        raise_error(
          "themes.import_error.migrations.wrong_return_type",
          name: migration.original_name,
        )
      else
        raise_error(
          "themes.import_error.migrations.runtime_error",
          name: migration.original_name,
          error: message,
        )
      end
    end
  end

  private

  def lookup_pending_migrations_fields
    @theme
      .migration_fields
      .left_joins(:theme_settings_migration)
      .where(theme_settings_migration: { id: nil })
  end

  def convert_fields_to_migrations(fields)
    fields.map do |field|
      match_data = /\A(?<version>\d{4})-(?<name>.+)/.match(field.name)

      if !match_data
        raise_error("themes.import_error.migrations.invalid_filename", filename: field.name)
      end

      version = match_data[:version].to_i
      name = match_data[:name]
      original_name = field.name

      Migration.new(
        version: version,
        name: name,
        original_name: original_name,
        code: field.value,
        theme_field_id: field.id,
      )
    end
  end

  def lookup_overriden_settings
    hash = {}
    @theme.theme_settings.each { |row| hash[row.name] = ThemeSettingsManager.cast_row_value(row) }
    hash
  end

  def execute(migration, settings)
    context = MiniRacer::Context.new(timeout: @timeout, max_memory: @memory)

    context.eval(self.class.loader_js_lib_content, filename: "loader.js")

    context.eval(
      DiscourseJsProcessor.transpile(migration.code, "", "discourse/theme/migration"),
      filename: "theme-#{@theme.id}-migration.js",
    )

    context.eval(MIGRATION_ENTRY_POINT_JS, filename: "migration-entrypoint.js")
    context.call("main", settings)
  ensure
    context&.dispose
  end

  def raise_error(message_key, **i18n_args)
    raise Theme::SettingsMigrationError.new(I18n.t(message_key, **i18n_args))
  end
end
