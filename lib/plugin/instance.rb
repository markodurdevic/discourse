# frozen_string_literal: true

require 'digest/sha1'
require 'fileutils'
require_dependency 'plugin/metadata'
require_dependency 'auth'

class Plugin::CustomEmoji
  def self.cache_key
    @@cache_key ||= "plugin-emoji"
  end

  def self.emojis
    @@emojis ||= {}
  end

  def self.register(name, url)
    @@cache_key = Digest::SHA1.hexdigest(cache_key + name)[0..10]
    emojis[name] = url
  end

  def self.unregister(name)
    emojis.delete(name)
  end

  def self.translations
    @@translations ||= {}
  end

  def self.translate(from, to)
    @@cache_key = Digest::SHA1.hexdigest(cache_key + from)[0..10]
    translations[from] = to
  end
end

class Plugin::Instance

  attr_accessor :path, :metadata
  attr_reader :admin_route

  # Memoized array readers
  [:assets,
   :color_schemes,
   :before_auth_initializers,
   :initializers,
   :javascripts,
   :locales,
   :service_workers,
   :styles,
   :themes,
   :csp_extensions,
 ].each do |att|
    class_eval %Q{
      def #{att}
        @#{att} ||= []
      end
    }
  end

  def seed_data
    @seed_data ||= HashWithIndifferentAccess.new({})
  end

  def self.find_all(parent_path)
    [].tap { |plugins|
      # also follows symlinks - http://stackoverflow.com/q/357754
      Dir["#{parent_path}/*/plugin.rb"].sort.each do |path|

        # tagging is included in core, so don't load it
        next if path =~ /discourse-tagging/

        source = File.read(path)
        metadata = Plugin::Metadata.parse(source)
        plugins << self.new(metadata, path)
      end
    }
  end

  def initialize(metadata = nil, path = nil)
    @metadata = metadata
    @path = path
    @idx = 0
  end

  def add_admin_route(label, location)
    @admin_route = { label: label, location: location }
  end

  def enabled?
    @enabled_site_setting ? SiteSetting.get(@enabled_site_setting) : true
  end

  delegate :name, to: :metadata

  def add_to_serializer(serializer, attr, define_include_method = true, &block)
    reloadable_patch do |plugin|
      base = "#{serializer.to_s.classify}Serializer".constantize rescue "#{serializer.to_s}Serializer".constantize

      # we have to work through descendants cause serializers may already be baked and cached
      ([base] + base.descendants).each do |klass|
        unless attr.to_s.start_with?("include_")
          klass.attributes(attr)

          if define_include_method
            # Don't include serialized methods if the plugin is disabled
            klass.public_send(:define_method, "include_#{attr}?") { plugin.enabled? }
          end
        end

        klass.public_send(:define_method, attr, &block)
      end
    end
  end

  # Applies to all sites in a multisite environment. Ignores plugin.enabled?
  def add_report(name, &block)
    reloadable_patch do |plugin|
      Report.add_report(name, &block)
    end
  end

  # Applies to all sites in a multisite environment. Ignores plugin.enabled?
  def replace_flags
    settings = ::FlagSettings.new
    yield settings

    reloadable_patch do |plugin|
      ::PostActionType.replace_flag_settings(settings)
    end
  end

  def whitelist_staff_user_custom_field(field)
    reloadable_patch do |plugin|
      ::User.register_plugin_staff_custom_field(field, plugin) # plugin.enabled? is checked at runtime
    end
  end

  def whitelist_public_user_custom_field(field)
    reloadable_patch do |plugin|
      ::User.register_plugin_public_custom_field(field, plugin) # plugin.enabled? is checked at runtime
    end
  end

  def register_editable_user_custom_field(field)
    reloadable_patch do |plugin|
      ::User.register_plugin_editable_user_custom_field(field, plugin) # plugin.enabled? is checked at runtime
    end
  end

  def register_editable_group_custom_field(field)
    reloadable_patch do |plugin|
      ::Group.register_plugin_editable_group_custom_field(field, plugin) # plugin.enabled? is checked at runtime
    end
  end

  def custom_avatar_column(column)
    reloadable_patch do |plugin|
      AvatarLookup.lookup_columns << column
      AvatarLookup.lookup_columns.uniq!
    end
  end

  # Applies to all sites in a multisite environment. Ignores plugin.enabled?
  def add_body_class(class_name)
    reloadable_patch do |plugin|
      ::ApplicationHelper.extra_body_classes << class_name
    end
  end

  def rescue_from(exception, &block)
    reloadable_patch do |plugin|
      ::ApplicationController.rescue_from(exception, &block)
    end
  end

  # Extend a class but check that the plugin is enabled
  # for class methods use `add_class_method`
  def add_to_class(class_name, attr, &block)
    reloadable_patch do |plugin|
      klass = class_name.to_s.classify.constantize rescue class_name.to_s.constantize
      hidden_method_name = :"#{attr}_without_enable_check"
      klass.public_send(:define_method, hidden_method_name, &block)

      klass.public_send(:define_method, attr) do |*args|
        public_send(hidden_method_name, *args) if plugin.enabled?
      end
    end
  end

  # Adds a class method to a class, respecting if plugin is enabled
  def add_class_method(klass_name, attr, &block)
    reloadable_patch do |plugin|
      klass = klass_name.to_s.classify.constantize rescue klass_name.to_s.constantize

      hidden_method_name = :"#{attr}_without_enable_check"
      klass.public_send(:define_singleton_method, hidden_method_name, &block)

      klass.public_send(:define_singleton_method, attr) do |*args|
        public_send(hidden_method_name, *args) if plugin.enabled?
      end
    end
  end

  def add_model_callback(klass_name, callback, options = {}, &block)
    reloadable_patch do |plugin|
      klass = klass_name.to_s.classify.constantize rescue klass_name.to_s.constantize

      # generate a unique method name
      method_name = "#{plugin.name}_#{klass.name}_#{callback}#{@idx}".underscore
      @idx += 1
      hidden_method_name = :"#{method_name}_without_enable_check"
      klass.public_send(:define_method, hidden_method_name, &block)

      klass.public_send(callback, options) do |*args|
        public_send(hidden_method_name, *args) if plugin.enabled?
      end

      hidden_method_name
    end
  end

  # Add a post_custom_fields_whitelister block to the TopicView, respecting if the plugin is enabled
  def topic_view_post_custom_fields_whitelister(&block)
    reloadable_patch do |plugin|
      ::TopicView.add_post_custom_fields_whitelister do |user|
        plugin.enabled? ? block.call(user) : []
      end
    end
  end

  # Applies to all sites in a multisite environment. Ignores plugin.enabled?
  def add_preloaded_group_custom_field(field)
    reloadable_patch do |plugin|
      ::Group.preloaded_custom_field_names << field
    end
  end

  # Applies to all sites in a multisite environment. Ignores plugin.enabled?
  def add_preloaded_topic_list_custom_field(field)
    reloadable_patch do |plugin|
      ::TopicList.preloaded_custom_fields << field
    end
  end

  # Add a permitted_create_param to Post, respecting if the plugin is enabled
  def add_permitted_post_create_param(name)
    reloadable_patch do |plugin|
      ::Post.plugin_permitted_create_params[name] = plugin
    end
  end

  # Add validation method but check that the plugin is enabled
  def validate(klass, name, &block)
    klass = klass.to_s.classify.constantize
    klass.public_send(:define_method, name, &block)

    plugin = self
    klass.validate(name, if: -> { plugin.enabled? })
  end

  # will make sure all the assets this plugin needs are registered
  def generate_automatic_assets!
    paths = []
    assets = []

    automatic_assets.each do |path, contents|
      write_asset(path, contents)
      paths << path
      assets << [path]
    end

    delete_extra_automatic_assets(paths)

    assets
  end

  def delete_extra_automatic_assets(good_paths)
    return unless Dir.exists? auto_generated_path

    filenames = good_paths.map { |f| File.basename(f) }
    # nuke old files
    Dir.foreach(auto_generated_path) do |p|
      next if [".", ".."].include?(p)
      next if filenames.include?(p)
      File.delete(auto_generated_path + "/#{p}")
    end
  end

  def ensure_directory(path)
    dirname = File.dirname(path)
    unless File.directory?(dirname)
      FileUtils.mkdir_p(dirname)
    end
  end

  def directory
    File.dirname(path)
  end

  def auto_generated_path
    File.dirname(path) << "/auto_generated"
  end

  def after_initialize(&block)
    initializers << block
  end

  def before_auth(&block)
    raise "Auth providers must be registered before omniauth middleware. after_initialize is too late!" if @before_auth_complete
    before_auth_initializers << block
  end

  # A proxy to `DiscourseEvent.on` which does nothing if the plugin is disabled
  def on(event_name, &block)
    DiscourseEvent.on(event_name) do |*args|
      block.call(*args) if enabled?
    end
  end

  def notify_after_initialize
    color_schemes.each do |c|
      unless ColorScheme.where(name: c[:name]).exists?
        ColorScheme.create_from_base(name: c[:name], colors: c[:colors])
      end
    end

    initializers.each do |callback|
      begin
        callback.call(self)
      rescue ActiveRecord::StatementInvalid => e
        # When running `db:migrate` for the first time on a new database,
        # plugin initializers might try to use models.
        # Tolerate it.
        raise e unless e.message.try(:include?, "PG::UndefinedTable")
      end
    end
  end

  def notify_before_auth
    before_auth_initializers.each do |callback|
      callback.call(self)
    end
    @before_auth_complete = true
  end

  # Applies to all sites in a multisite environment. Ignores plugin.enabled?
  def register_category_custom_field_type(name, type)
    reloadable_patch do |plugin|
      Category.register_custom_field_type(name, type)
    end
  end

  # Applies to all sites in a multisite environment. Ignores plugin.enabled?
  def register_topic_custom_field_type(name, type)
    reloadable_patch do |plugin|
      ::Topic.register_custom_field_type(name, type)
    end
  end

  # Applies to all sites in a multisite environment. Ignores plugin.enabled?
  def register_post_custom_field_type(name, type)
    reloadable_patch do |plugin|
      ::Post.register_custom_field_type(name, type)
    end
  end

  # Applies to all sites in a multisite environment. Ignores plugin.enabled?
  def register_group_custom_field_type(name, type)
    reloadable_patch do |plugin|
      ::Group.register_custom_field_type(name, type)
    end
  end

  # Applies to all sites in a multisite environment. Ignores plugin.enabled?
  def register_user_custom_field_type(name, type)
    reloadable_patch do |plugin|
      ::User.register_custom_field_type(name, type)
    end
  end

  def register_seedfu_fixtures(paths)
    paths = [paths] if !paths.kind_of?(Array)
    SeedFu.fixture_paths.concat(paths)
  end

  def listen_for(event_name)
    return unless self.respond_to?(event_name)
    DiscourseEvent.on(event_name, &self.method(event_name))
  end

  def register_css(style)
    styles << style
  end

  def register_javascript(js)
    javascripts << js
  end

  def register_svg_icon(icon)
    DiscoursePluginRegistry.register_svg_icon(icon)
  end

  def extend_content_security_policy(extension)
    csp_extensions << extension
  end

  # @option opts [String] :name
  # @option opts [String] :nativeName
  # @option opts [String] :fallbackLocale
  # @option opts [Hash] :plural
  def register_locale(locale, opts = {})
    locales << [locale, opts]
  end

  def register_custom_html(hash)
    DiscoursePluginRegistry.custom_html ||= {}
    DiscoursePluginRegistry.custom_html.merge!(hash)
  end

  def register_html_builder(name, &block)
    DiscoursePluginRegistry.register_html_builder(name, &block)
  end

  def register_asset(file, opts = nil)
    if opts && opts == :vendored_core_pretty_text
      full_path = DiscoursePluginRegistry.core_asset_for_name(file)
    else
      full_path = File.dirname(path) << "/assets/" << file
    end

    assets << [full_path, opts, directory_name]
  end

  def register_service_worker(file, opts = nil)
    service_workers << [
      File.join(File.dirname(path), 'assets', file),
      opts
    ]
  end

  def register_color_scheme(name, colors)
    color_schemes << { name: name, colors: colors }
  end

  def register_seed_data(key, value)
    seed_data[key] = value
  end

  def register_seed_path_builder(&block)
    DiscoursePluginRegistry.register_seed_path_builder(&block)
  end

  def register_emoji(name, url)
    Plugin::CustomEmoji.register(name, url)
  end

  def translate_emoji(from, to)
    Plugin::CustomEmoji.translate(from, to)
  end

  def automatic_assets
    css = styles.join("\n")
    js = javascripts.join("\n")

    # Generate an IIFE for the JS
    js = "(function(){#{js}})();" if js.present?

    result = []
    result << [css, 'css'] if css.present?
    result << [js, 'js'] if js.present?

    result.map do |asset, extension|
      hash = Digest::SHA1.hexdigest asset
      ["#{auto_generated_path}/plugin_#{hash}.#{extension}", asset]
    end
  end

  # note, we need to be able to parse seperately to activation.
  # this allows us to present information about a plugin in the UI
  # prior to activations
  def activate!

    if @path
      # Automatically include all ES6 JS and hbs files
      root_path = "#{File.dirname(@path)}/assets/javascripts"
      DiscoursePluginRegistry.register_glob(root_path, 'js.es6')
      DiscoursePluginRegistry.register_glob(root_path, 'hbs')

      admin_path = "#{File.dirname(@path)}/admin/assets/javascripts"
      DiscoursePluginRegistry.register_glob(admin_path, 'js.es6', admin: true)
      DiscoursePluginRegistry.register_glob(admin_path, 'hbs', admin: true)
    end

    self.instance_eval File.read(path), path
    if auto_assets = generate_automatic_assets!
      assets.concat(auto_assets)
    end

    register_assets! unless assets.blank?
    register_locales!
    register_service_workers!

    seed_data.each do |key, value|
      DiscoursePluginRegistry.register_seed_data(key, value)
    end

    # TODO: possibly amend this to a rails engine

    # Automatically include assets
    Rails.configuration.assets.paths << auto_generated_path
    Rails.configuration.assets.paths << File.dirname(path) + "/assets"
    Rails.configuration.assets.paths << File.dirname(path) + "/admin/assets"
    Rails.configuration.assets.paths << File.dirname(path) + "/test/javascripts"

    # Automatically include rake tasks
    Rake.add_rakelib(File.dirname(path) + "/lib/tasks")

    # Automatically include migrations
    migration_paths = ActiveRecord::Migrator.migrations_paths
    migration_paths << File.dirname(path) + "/db/migrate"

    unless Discourse.skip_post_deployment_migrations?
      migration_paths << "#{File.dirname(path)}/#{Discourse::DB_POST_MIGRATE_PATH}"
    end

    public_data = File.dirname(path) + "/public"
    if Dir.exists?(public_data)
      target = Rails.root.to_s + "/public/plugins/"

      Discourse::Utils.execute_command('mkdir', '-p', target)
      target << name.gsub(/\s/, "_")
      # TODO a cleaner way of registering and unregistering
      Discourse::Utils.execute_command('rm', '-f', target)
      Discourse::Utils.execute_command('ln', '-s', public_data, target)
    end

    ensure_directory(Plugin::Instance.js_path)

    contents = []
    handlebars_includes.each { |hb| contents << "require_asset('#{hb}')" }
    javascript_includes.each { |js| contents << "require_asset('#{js}')" }

    each_globbed_asset do |f, is_dir|
      contents << (is_dir ? "depend_on('#{f}')" : "require_asset('#{f}')")
    end

    File.delete(js_file_path) if js_asset_exists?

    if contents.present?
      contents.insert(0, "<%")
      contents << "%>"
      write_asset(js_file_path, contents.join("\n"))
    end
  end

  def auth_provider(opts)
    before_auth do
      provider = Auth::AuthProvider.new

      Auth::AuthProvider.auth_attributes.each do |sym|
        provider.public_send("#{sym}=", opts.delete(sym)) if opts.has_key?(sym)
      end

      begin
        provider.authenticator.enabled?
      rescue NotImplementedError
        provider.authenticator.define_singleton_method(:enabled?) do
          Discourse.deprecate("#{provider.authenticator.class.name} should define an `enabled?` function. Patching for now.")
          return SiteSetting.get(provider.enabled_setting) if provider.enabled_setting
          Discourse.deprecate("#{provider.authenticator.class.name} has not defined an enabled_setting. Defaulting to true.")
          true
        end
      end

      DiscoursePluginRegistry.register_auth_provider(provider)
    end
  end

  # shotgun approach to gem loading, in future we need to hack bundler
  #  to at least determine dependencies do not clash before loading
  #
  # Additionally we want to support multiple ruby versions correctly and so on
  #
  # This is a very rough initial implementation
  def gem(name, version, opts = {})
    PluginGem.load(path, name, version, opts)
  end

  def hide_plugin
    Discourse.hidden_plugins << self
  end

  def enabled_site_setting_filter(filter = nil)
    if filter
      @enabled_setting_filter = filter
    else
      @enabled_setting_filter
    end
  end

  def enabled_site_setting(setting = nil)
    if setting
      @enabled_site_setting = setting
    else
      @enabled_site_setting
    end
  end

  def handlebars_includes
    assets.map do |asset, opts|
      next if opts == :admin
      next unless asset =~ DiscoursePluginRegistry::HANDLEBARS_REGEX
      asset
    end.compact
  end

  def javascript_includes
    assets.map do |asset, opts|
      next if opts == :vendored_core_pretty_text
      next if opts == :admin
      next unless asset =~ DiscoursePluginRegistry::JS_REGEX
      asset
    end.compact
  end

  def each_globbed_asset
    if @path
      # Automatically include all ES6 JS and hbs files
      root_path = "#{File.dirname(@path)}/assets/javascripts"

      Dir.glob("#{root_path}/**/*") do |f|
        if File.directory?(f)
          yield [f, true]
        elsif f.to_s.ends_with?(".js.es6") || f.to_s.ends_with?(".hbs")
          yield [f, false]
        end
      end
    end
  end

  def register_reviewable_type(reviewable_type_class)
    extend_list_method Reviewable, :types, [reviewable_type_class.name]
  end

  def extend_list_method(klass, method, new_attributes)
    current_list = klass.public_send(method)
    current_list.concat(new_attributes)

    reloadable_patch do
      klass.public_send(:define_singleton_method, method) { current_list }
    end
  end

  def directory_name
    @directory_name ||= File.dirname(path).split("/").last
  end

  def css_asset_exists?(target = nil)
    DiscoursePluginRegistry.stylesheets_exists?(directory_name, target)
  end

  def js_asset_exists?
    File.exists?(js_file_path)
  end

  protected

  def self.js_path
    File.expand_path "#{Rails.root}/app/assets/javascripts/plugins"
  end

  def js_file_path
    @file_path ||= "#{Plugin::Instance.js_path}/#{directory_name}.js.erb"
  end

  def register_assets!
    assets.each do |asset, opts, plugin_directory_name|
      DiscoursePluginRegistry.register_asset(asset, opts, plugin_directory_name)
    end
  end

  def register_service_workers!
    service_workers.each do |asset, opts|
      DiscoursePluginRegistry.register_service_worker(asset, opts)
    end
  end

  def register_locales!
    root_path = File.dirname(@path)

    locales.each do |locale, opts|
      opts = opts.dup
      opts[:client_locale_file] = File.join(root_path, "config/locales/client.#{locale}.yml")
      opts[:server_locale_file] = File.join(root_path, "config/locales/server.#{locale}.yml")
      opts[:js_locale_file] = File.join(root_path, "assets/locales/#{locale}.js.erb")

      locale_chain = opts[:fallbackLocale] ? [locale, opts[:fallbackLocale]] : [locale]
      lib_locale_path = File.join(root_path, "lib/javascripts/locale")

      path = File.join(lib_locale_path, "message_format")
      opts[:message_format] = find_locale_file(locale_chain, path)
      opts[:message_format] = JsLocaleHelper.find_message_format_locale(locale_chain, fallback_to_english: false) unless opts[:message_format]

      path = File.join(lib_locale_path, "moment_js")
      opts[:moment_js] = find_locale_file(locale_chain, path)
      opts[:moment_js] = JsLocaleHelper.find_moment_locale(locale_chain) unless opts[:moment_js]

      path = File.join(lib_locale_path, "moment_js_timezones")
      opts[:moment_js_timezones] = find_locale_file(locale_chain, path)
      opts[:moment_js_timezones] = JsLocaleHelper.find_moment_locale(locale_chain, timezone_names: true) unless opts[:moment_js_timezones]

      if valid_locale?(opts)
        DiscoursePluginRegistry.register_locale(locale, opts)
        Rails.configuration.assets.precompile << "locales/#{locale}.js"
      else
        msg = "Invalid locale! #{opts.inspect}"
        # The logger isn't always present during boot / parsing locales from plugins
        if Rails.logger.present?
          Rails.logger.error(msg)
        else
          puts msg
        end
      end
    end
  end

  def allow_new_queued_post_payload_attribute(attribute_name)
    reloadable_patch do
      NewPostManager.add_plugin_payload_attribute(attribute_name)
    end
  end

  private

  def write_asset(path, contents)
    unless File.exists?(path)
      ensure_directory(path)
      File.open(path, "w") { |f| f.write(contents) }
    end
  end

  def reloadable_patch(plugin = self)
    if Rails.env.development? && defined?(ActiveSupport::Reloader)
      ActiveSupport::Reloader.to_prepare do
        # reload the patch
        yield plugin
      end
    end

    # apply the patch
    yield plugin
  end

  def valid_locale?(custom_locale)
    File.exist?(custom_locale[:client_locale_file]) &&
      File.exist?(custom_locale[:server_locale_file]) &&
      File.exist?(custom_locale[:js_locale_file]) &&
      custom_locale[:message_format] && custom_locale[:moment_js]
  end

  def find_locale_file(locale_chain, path)
    locale_chain.each do |locale|
      filename = File.join(path, "#{locale}.js")
      return [locale, filename] if File.exist?(filename)
    end
    nil
  end
end
