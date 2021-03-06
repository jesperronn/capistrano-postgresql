require 'capistrano/postgresql/helper_methods'
require 'capistrano/postgresql/password_helpers'
require 'capistrano/postgresql/psql_helpers'

require 'pry'

include Capistrano::Postgresql::HelperMethods
include Capistrano::Postgresql::PasswordHelpers
include Capistrano::Postgresql::PsqlHelpers

namespace :load do
  task :defaults do
    set :system_user, 'root' # Used for SCP commands to deploy files to remote servers
    set :pg_database, -> { "#{fetch(:application)}_#{fetch(:stage)}" }
    set :pg_user, -> { fetch(:pg_database) }
    set :pg_ask_for_password, false
    set :pg_password, -> { ask_for_or_generate_password }
    set :pg_system_user, 'postgres'
    set :pg_without_sudo, false # issues/22 | Contributed by snake66
    set :pg_system_db, 'postgres'
    set :pg_use_hstore, false
    set :pg_extensions, []
    # template only settings
    set :pg_templates_path, 'config/deploy/templates'
    set :pg_env, -> { fetch(:rails_env) || fetch(:stage) }
    set :pg_pool, 5
    set :pg_encoding, 'unicode'
    # for multiple release nodes automatically use server hostname (IP?) in the database.yml
    set :pg_host, -> do
      if release_roles(:all).count == 1 && release_roles(:all).first == primary(:db)
        'localhost'
      else
        primary(:db).hostname
      end
    end
  end
end

namespace :postgresql do

  desc 'Steps to upgrade the gem to version 4.0'
  task :upgrade4 do
    on roles :db do
      execute :mkdir, '-pv', File.dirname(archetype_database_yml_file)
      execute :cp, database_yml_file, archetype_database_yml_file
    end
  end

  # undocumented, for a reason: drops database. Use with care!
  task :remove_all do
    on release_roles :all do
      if test "[ -e #{database_yml_file} ]"
        execute :rm, database_yml_file
      end
    end

    on primary :db do
      if test "[ -e #{archetype_database_yml_file} ]"
        execute :rm, archetype_database_yml_file
      end
    end

    on roles :db do
      psql '-c', %Q{"DROP database \\"#{fetch(:pg_database)}\\";"}
      psql '-c', %Q{"DROP user \\"#{fetch(:pg_user)}\\";"}
    end
  end

  task :remove_yml_files do
    on release_roles :all do
      if test "[ -e #{database_yml_file} ]"
        execute :rm, database_yml_file
      end
    end
    on primary :db do
      if test "[ -e #{archetype_database_yml_file} ]"
        execute :rm, archetype_database_yml_file
      end
    end
  end

  desc 'Remove pg_extension from postgresql db'
  task :remove_extensions do
    next unless Array( fetch(:pg_extensions) ).any?
    on roles :db do
      # remove in reverse order if extension is present
      Array( fetch(:pg_extensions) ).reverse.each do |ext|
        psql_on_app_db '-c', %Q{"DROP EXTENSION IF EXISTS #{ext};"} unless [nil, false, ""].include?(ext)
      end
    end
  end

  desc 'Add the hstore extension to postgresql'
  task :add_hstore do
    next unless fetch(:pg_use_hstore)
    on roles :db do
      psql_on_app_db '-c', %Q{"CREATE EXTENSION IF NOT EXISTS hstore;"}
    end
  end

  desc 'Add pg_extension to postgresql db'
  task :add_extensions do
    next unless Array( fetch(:pg_extensions) ).any?
    on roles :db do
      Array( fetch(:pg_extensions) ).each do |ext|
        next if [nil, false, ""].include?(ext)
        if psql_on_app_db '-c', %Q{"CREATE EXTENSION IF NOT EXISTS #{ext};"}
          puts "- Added extension #{ext} to #{fetch(:pg_database)}"
        else
          error "postgresql: adding extension #{ext} failed!"
          exit 1
        end
      end
    end
  end

  desc 'Create DB user'
  task :create_db_user do
    on roles :db do
      next if db_user_exists?
      # If you use CREATE USER instead of CREATE ROLE the LOGIN right is granted automatically; otherwise you must specify it in the WITH clause of the CREATE statement.
      unless psql '-c', %Q{"CREATE USER \\"#{fetch(:pg_user)}\\" PASSWORD '#{fetch(:pg_password)}';"}
        error 'postgresql: creating database user failed!'
        exit 1
      end
    end
  end

  desc 'Create database'
  task :create_database do
    on roles :db do
      next if database_exists?
      unless psql '-c', %Q{"CREATE DATABASE \\"#{fetch(:pg_database)}\\" OWNER \\"#{fetch(:pg_user)}\\";"}
        error 'postgresql: creating database failed!'
        exit 1
      end
    end
  end

  # This task creates the archetype database.yml file on the primary db server. This is done once when a
  # new DB user is created.
  desc 'Generate database.yml archetype'
  task :generate_database_yml_archetype do
    on primary :db do
      next if test "[ -e #{archetype_database_yml_file} ]"
      execute :mkdir, '-pv', File.dirname(archetype_database_yml_file)
      Net::SCP.upload!(fetch(:pg_host), fetch(:system_user), pg_template('postgresql.yml.erb'), archetype_database_yml_file)
    end
  end

  # This task copies the archetype database file on the primary db server to all clients. This is done on
  # every setup, to ensure new servers get a copy as well.
  desc 'Copy archetype database.yml from primary db server to clients'
  task :generate_database_yml do
    database_yml_contents = nil
    on primary :db do
      database_yml_contents = download! archetype_database_yml_file
    end

    on release_roles :all do
      execute :mkdir, '-pv', File.dirname(database_yml_file)
      Net::SCP.upload!(self.host.hostname, fetch(:system_user), StringIO.new(database_yml_contents), database_yml_file)
    end
  end

  task :database_yml_symlink do
    set :linked_files, fetch(:linked_files, []).push('config/database.yml')
  end

  after 'deploy:started', 'postgresql:database_yml_symlink'

  desc 'Postgresql setup tasks'
  task :setup do
    puts "* ============================= * \n All psql commands will be run #{fetch(:pg_without_sudo) ? 'without sudo' : 'with sudo'}\n You can modify this in your deploy/{env}.rb by setting the pg_without_sudo boolean \n* ============================= *"
    invoke 'postgresql:remove_yml_files' # Delete old yml files. Allows you to avoid having to manually delete the files on your web/app servers to get a new pool size for example.
    invoke 'postgresql:create_db_user'
    invoke 'postgresql:create_database'
    invoke 'postgresql:add_hstore'
    invoke 'postgresql:add_extensions'
    invoke 'postgresql:generate_database_yml_archetype'
    invoke 'postgresql:generate_database_yml'
  end
end

desc 'Server setup tasks'
task :setup do
  invoke "postgresql:setup"
end
