# frozen_string_literal: true

require "sprockets/version"
require 'sprockets/sass_processor'
require "sprockets/utils"

module SassC::Rails
  class SassTemplate < Sprockets::SassProcessor
    def initialize(options = {}, &block)
      @cache_version = options[:cache_version]
      @cache_key = "#{self.class.name}:#{VERSION}:#{SassC::VERSION}:#{@cache_version}".freeze
      #@importer_class = options[:importer] || Sass::Importers::Filesystem
      @sass_config = options[:sass_config] || {}
      @functions = Module.new do
        include Functions
        include options[:functions] if options[:functions]
        class_eval(&block) if block_given?
      end
    end

    def call(input)
      context = input[:environment].context_class.new(input)
      support_source_maps = Rails.application.config.assets.debug && !Sprockets::VERSION.start_with?("3")

      options = {
        filename: input[:filename],
        line_comments: line_comments?,
        syntax: self.class.syntax,
        load_paths: input[:environment].paths,
        importer: SassC::Rails::Importer,
        sprockets: {
          context: context,
          environment: input[:environment],
          dependencies: context.metadata[:dependency_paths]
        }
      }.merge!(config_options) { |key, left, right| safe_merge(key, left, right) }

      if support_source_maps
        options.merge!(
          source_map_contents: false,
          source_map_file: "#{input[:filename]}.map",
          omit_source_map_url: true,
        )
      end

      engine = ::SassC::Engine.new(input[:data], options)

      css = Sprockets::Utils.module_include(::SassC::Script::Functions, @functions) do
        engine.render
      end

      return context.metadata.merge(data: css) unless support_source_maps

      begin
        map = Sprockets::SourceMapUtils.format_source_map(JSON.parse(engine.source_map), input)
        map = Sprockets::SourceMapUtils.combine_source_maps(input[:metadata][:map], map)

        engine.dependencies.each do |dependency|
          context.metadata[:dependencies] << Sprockets::URIUtils.build_file_digest_uri(dependency.filename)
        end
      rescue SassC::NotRenderedError
        map = input[:metadata][:map]
      end

      context.metadata.merge(data: css, map: map)
    end

    def config_options
      opts = { style: sass_style, load_paths: load_paths }


      if Rails.application.config.sass.inline_source_maps
        opts.merge!({
          source_map_file: ".",
          source_map_embed: true,
          source_map_contents: true,
        })
      end

      opts
    end

    def sass_style
      (Rails.application.config.sass.style || :expanded).to_sym
    end

    def load_paths
      Rails.application.config.sass.load_paths || []
    end

    def line_comments?
      Rails.application.config.sass.line_comments
    end

    def safe_merge(_key, left, right)
      if [left, right].all? { |v| v.is_a? Hash }
        left.merge(right) { |k, l, r| safe_merge(k, l, r) }
      elsif [left, right].all? { |v| v.is_a? Array }
        (left + right).uniq
      else
        right
      end
    end

    # The methods in the Functions module were copied here from sprockets in order to
    # override the Value class names (e.g. ::SassC::Script::Value::String)
    module Functions
      def asset_path(path, options = {})
        path = path.value

        path, _, query, fragment = URI.split(path)[5..8]
        path     = sprockets_context.asset_path(path, options)
        query    = "?#{query}" if query
        fragment = "##{fragment}" if fragment

        ::SassC::Script::Value::String.new("#{path}#{query}#{fragment}", :string)
      end

      def asset_url(path, options = {})
        ::SassC::Script::Value::String.new("url(#{asset_path(path, options).value})")
      end

      def asset_data_url(path)
        url = sprockets_context.asset_data_uri(path.value)
        ::SassC::Script::Value::String.new("url(" + url + ")")
      end
    end
  end

  class ScssTemplate < SassTemplate
    def self.syntax
      :scss
    end
  end
end
