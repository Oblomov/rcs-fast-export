#!/usr/bin/ruby

require 'pp'

def usage
	STDERR.puts <<EOM
#{$0} [options] file [file ...]

Fast-export the RCS history of one or more file.

Options:
	--help, -h, -?		display this help text
	--authors-file, -A	specify a file containing username = Full Name <email> mappings
	--[no-]tag-each-rev	[do not] create a lightweight tag for each RCS revision

Config options:
	rcs.authorsFile		for --authors-file
	rcs.tagEachRev		for --tag-each-rev

EOM
end

def not_found(arg)
	STDERR.puts "Could not find #{arg}"
end

# returns a hash that maps usernames to author names & emails
def load_authors_file(fn)
	hash = {}
	begin
		File.open(File.expand_path fn) do |io|
			io.each_line do |line|
				uname, author = line.split('=', 2)
				uname.strip!
				author.strip!
				STDERR.puts "Username #{uname} redefined to #{author}" if hash.has_key? uname
				hash[uname] = author
			end
		end
	rescue
		not_found(fn)
	end
	return hash
end

class Time
	def Time.rcs(string)
		fields = string.split('.')
		raise ArgumentError, "wrong number of fields for RCS date #{string}" unless fields.length == 6
		Time.utc(*fields)
	end
end

module RCS
	# strip an optional final ;
	def RCS.clean(arg)
		arg.chomp(';')
	end

	# strip the first and last @, and de-double @@s
	def RCS.sanitize(arg)
		case arg
		when Array
			ret = arg.dup
			raise 'malformed first line' unless ret.first[0,1] == '@'
			raise 'malformed last line' unless ret.last[-1,1] == '@'
			ret.first.sub!(/^@/,'')
			ret.last.sub!(/@$/,'')
			ret.map { |l| l.gsub('@@','@') }
		when String
			arg.chomp('@').sub(/^@/,'').gsub('@@','@')
		else
			raise
		end
	end

	# clean and sanitize
	def RCS.at_clean(arg)
		RCS.sanitize RCS.clean(arg)
	end

	def RCS.blob(arg)
		arg.gsub('.', '0') + ('90'*5)
	end

	def RCS.commit(arg)
		arg.gsub('.', '0') + ('09'*5)
	end

	class File
		attr_accessor :head, :comment, :desc, :revision
		def initialize(fname)
			@fname = fname.dup
			@head = nil
			@comment = nil
			@desc = []
			@revision = Hash.new { |h, r| h[r] = Revision.new(r) }
		end

		def has_revision?(rev)
			@revision.has_key?(rev) and not @revision[rev].author.nil?
		end

		def export_commits(opts={})
			counter = 0
			exported = []
			until @revision.empty?
				counter += 1

				# a string sort is a very good candidate for
				# export order, getting a miss only for
				# multi-digit revision components
				keys = @revision.keys.sort

				STDERR.puts "commit export loop ##{counter}"
				STDERR.puts "\t#{exported.length} commits exported so far: #{exported.join(', ')}" unless exported.empty?
				STDERR.puts "\t#{keys.size} to export: #{keys.join(', ')}"

				keys.each do |key|
					rev = @revision[key]
					# the parent commit is rev.next if we're on the
					# master branch (rev.branch is nil) or
					# rev.diff_base otherwise
					from = rev.branch.nil? ? rev.next : rev.diff_base
					# A commit can only be exported if it has no
					# parent, or if the parent has been exported
					# already. Skip this commit otherwise
					if from and not exported.include? from
						next
					end

					branch = rev.branch || 'master'
					author = opts[:authors][rev.author] || "#{rev.author} <empty>"
					date = "#{rev.date.tv_sec} +0000"
					log = rev.log.to_s

					puts "commit refs/heads/#{branch}"
					puts "mark :#{RCS.commit key}"
					puts "committer #{author} #{date}"
					puts "data #{log.length}"
					puts log unless log.empty?
					puts "from :#{RCS.commit from}" if rev.branch_point
					puts "M 644 :#{RCS.blob key} #{@fname}"

					# TODO FIXME this *should* be safe, in
					# that it should not unduly move
					# branches back in time, but I'm not
					# 100% sure ...
					rev.branches.each do |sym|
						puts "reset refs/heads/#{sym}"
						puts "from :#{RCS.commit key}"
					end
					rev.symbols.each do |sym|
						puts "reset refs/tags/#{sym}"
						puts "from :#{RCS.commit key}"
					end
					if opts[:tag_each_rev]
						puts "reset refs/tags/#{key}"
						puts "from :#{RCS.commit key}"
					end

					exported.push key
				end
				exported.each { |k| @revision.delete(k) }
			end
		end
	end

	class Revision
		attr_accessor :rev, :author, :date, :state, :next
		attr_accessor :branches, :log, :text, :symbols
		attr_accessor :branch, :diff_base, :branch_point
		def initialize(rev)
			@rev = rev
			@author = nil
			@date = nil
			@state = nil
			@next = nil
			@branches = []
			@branch = nil
			@branch_point = nil
			@diff_base = nil
			@log = []
			@text = []
			@symbols = []
		end

		def date=(str)
			@date = Time.rcs(str)
		end

		def blob
			str = @text.join('')
			ret = "blob\nmark :#{RCS.blob @rev}\ndata #{str.length}\n#{str}\n"
			ret
		end
	end

	def RCS.parse(fname, rcsfile, opts={})
		rcs = RCS::File.new(fname)

		::File.open(rcsfile, 'r') do |file|
			status = [:basic]
			rev = nil
			lines = []
			difflines = []
			file.each_line do |line|
				case status.last
				when :basic
					command, args = line.split($;,2)
					next if command.empty?

					case command
					when 'head'
						rcs.head = RCS.clean(args.chomp)
					when 'symbols'
						status.push :symbols
					when 'comment'
						rcs.comment = RCS.at_clean(args.chomp)
					when /^[0-9.]+$/
						rev = command.dup
						if rcs.has_revision?(rev)
							status.push :revision_data
						else
							status.push :new_revision
						end
					when 'desc'
						status.push :desc
						lines.clear
						status.push :read_lines
					else
						STDERR.puts "Skipping unhandled command #{command.inspect}"
					end
				when :symbols
					sym, rev = line.strip.split(':',2);
					status.pop if rev.chomp!(';')
					rcs.revision[rev].symbols << sym
				when :desc
					rcs.desc.replace lines.dup
					status.pop
				when :read_lines
					# we sanitize lines as we read them

					actual_line = line.dup

					# the first line must begin with a @, which we strip
					if lines.empty?
						ats = line.match(/^@+/)
						raise 'malformed line' unless ats
						actual_line.replace line.sub(/^@/,'')
					end

					# if the line ends with an ODD number of @, it's the
					# last line -- we work on actual_line so that content
					# such as @\n or @ work correctly (they would be
					# encoded respectively as ['@@@\n','@\n'] and
					# ['@@@@\n']
					ats = actual_line.chomp.match(/@+$/)
					if nomore = (ats && Regexp.last_match(0).length.odd?)
						actual_line.replace actual_line.chomp.sub(/@$/,'')
					end
					lines << actual_line.gsub('@@','@')
					if nomore
						status.pop
						redo
					end
				when :new_revision
					case line.chomp
					when /^date\s+(\S+);\s+author\s+(\S+);\sstate\s(\S+);$/
						rcs.revision[rev].date = $1
						rcs.revision[rev].author = $2
						rcs.revision[rev].state = $3
					when 'branches'
						status.push :branches
					when 'branches;'
						next
					when /^next\s+(\S+)?;$/
						nxt = rcs.revision[rev].next = $1
						next unless nxt
						raise "multiple diff_bases for #{nxt}" unless rcs.revision[nxt].diff_base.nil?
						rcs.revision[nxt].diff_base = rev
						rcs.revision[nxt].branch = rcs.revision[rev].branch
					else
						status.pop
					end
				when :branches
					candidate = line.split(';',2)
					branch = candidate.first.strip
					rcs.revision[rev].branches.push branch
					raise "multiple diff_bases for #{branch}" unless rcs.revision[branch].diff_base.nil?
					rcs.revision[branch].diff_base = rev
					# we drop the last number from the branch name
					rcs.revision[branch].branch = branch.sub(/\.\d+$/,'.x')
					rcs.revision[branch].branch_point = rev
					status.pop if candidate.length > 1
				when :revision_data
					case line.chomp
					when 'log'
						status.push :log
						lines.clear
						status.push :read_lines
					when 'text'
						if rev == rcs.head
							status.push :head
						else
							status.push :diff
						end
						lines.clear
						status.push :read_lines
					else
						status.pop
					end
				when :log
					rcs.revision[rev].log.replace lines.dup
					status.pop
				when :head
					rcs.revision[rev].text.replace lines.dup
					puts rcs.revision[rev].blob
					status.pop
				when :diff
					difflines.replace lines.dup
					difflines.pop if difflines.last.empty?
					base = rcs.revision[rev].diff_base
					unless rcs.revision[base].text
						pp rcs
						puts rev, base
						raise 'no diff base!'
					end
					# deep copy
					buffer = []
					rcs.revision[base].text.each { |l| buffer << l.dup }

					adding = false
					index = -1
					count = -1

					while l = difflines.shift
						if adding
							buffer[index] << l
							count -= 1
							adding = false unless count > 0
							next
						end

						l.chomp!
						raise 'malformed diff' unless l =~ /^([ad])(\d+) (\d+)$/
						index = $2.to_i-1
						count = $3.to_i
						case $1.intern
						when :d
							# we replace them with empty string so that 'a' commands
							# referring to the same line work properly
							while count > 0
								buffer[index].replace ''
								index += 1
								count -= 1
							end
						when :a
							adding = true
						end
					end

					# remove empty lines
					buffer.delete_if { |l| l.empty? }

					rcs.revision[rev].text = buffer
					puts rcs.revision[rev].blob
					status.pop
				else
					STDERR.puts "Unknown status #{status.last}"
					exit 1
				end
			end
		end

		# clean up the symbols/branches: look for revisions that have
		# one or more symbols but no dates, and make them into
		# branches, pointing to the highest commit with that key
		branches = []
		keys = rcs.revision.keys
		rcs.revision.each do |key, rev|
			if rev.date.nil? and not rev.symbols.empty?
				top = keys.select { |k| k.match(/^#{key}\./) }.sort.last
				tr = rcs.revision[top]
				raise "unhandled complex branch structure met: #{rev.inspect} refers #{tr.inspect}" if tr.date.nil?
				tr.branches |= rev.symbols
				branches << key
			end
		end
		branches.each { |k| rcs.revision.delete k }

		# export the commits
		rcs.export_commits(opts)
	end
end

require 'getoptlong'

opts = GetoptLong.new(
	# Authors file, like git-svn and git-cvsimport, more than one can be
	# specified
	['--authors-file', '-A', GetoptLong::REQUIRED_ARGUMENT],
	# RCS file suffix, like RCS
	['--rcs-suffixes', '-x', GetoptLong::REQUIRED_ARGUMENT],
	# tag each revision?
	['--tag-each-rev', GetoptLong::NO_ARGUMENT],
	['--no-tag-each-rev', GetoptLong::NO_ARGUMENT],
	['--help', '-h', '-?', GetoptLong::NO_ARGUMENT]
)

# We read options in order, but they apply to all passed parameters.
# TODO maybe they should only apply to the following, unless there's only one
# file?
opts.ordering = GetoptLong::RETURN_IN_ORDER

file_list = []
parse_options = {
	:authors => Hash.new,
}

# Read config options
`git config --get-all rcs.authorsfile`.each_line do |fn|
	parse_options[:authors].merge! load_authors_file(fn.chomp)
end

parse_options[:tag_each_rev] = (
	`git config --bool rcs.tageachrev`.chomp == 'true'
) ? true : false

opts.each do |opt, arg|
	case opt
	when '--authors-file'
		authors = load_authors_file(arg)
		redef = parse_options[:authors].keys & authors.keys
		STDERR.puts "Authors file #{arg} redefines #{redef.join(', ')}" unless redef.empty?
		parse_options[:authors].merge!(authors)
	when '--rcs-suffixes'
		# TODO
	when '--tag-each-rev'
		parse_options[:tag_each_rev] = true
	when '--no-tag-each-rev'
		# this is the default, which is fine since the missing key
		# (default) returns nil which is false in Ruby
		parse_options[:tag_each_rev] = false
	when ''
		file_list << arg
	when '--help'
		usage
		exit
	end
end

require 'etc'

user = Etc.getlogin || ENV['USER']

# steal username/email data from other init files that may contain the
# information
def steal_username
	[
		# the user's .hgrc file for a username field
		['~/.hgrc',   /^\s*username\s*=\s*(["'])?(.*)\1$/,       2],
		# the user's .(g)vimrc for a changelog_username setting
		['~/.vimrc',  /changelog_username\s*=\s*(["'])?(.*)\1$/, 2],
		['~/.gvimrc', /changelog_username\s*=\s*(["'])?(.*)\1$/, 2],
		[]
	].each do |fn, rx, idx|
		file = File.expand_path fn
		if File.readable?(file) and File.read(file) =~ rx
			parse_options[:authors][user] = Regexp.last_match(idx).strip
			break
		end
	end
end

if user and not user.empty? and not parse_options[:authors].has_key?(user)
	name = ENV['GIT_AUTHOR_NAME'] || ''
	name.replace(`git config user.name`.chomp) if name.empty?
	name.replace(Etc.getpwnam(user).gecos) if name.empty?

	if name.empty?
		# couldn't find a name, try to steal data from other sources
		steal_username
	else
		# if we found a name, try to find an email too
		email = ENV['GIT_AUTHOR_EMAIL'] || ''
		email.replace(`git config user.email`.chomp) if email.empty?

		if email.empty?
			# couldn't find an email, try to steal data too
			steal_username
		else
			# we got both a name and email, fill the info
			parse_options[:authors][user] = "#{name} <#{email}>"
		end
	end
end

if file_list.empty?
	usage
	exit 1
end

SFX = ',v'

status = 0

file_list.each do |arg|
	if arg[-2,2] == SFX
		if File.exists? arg
			rcsfile = arg.dup
		else
			not_found "RCS file #{arg}"
			status |= 1
		end
		filename = File.basename(arg, SFX)
	else
		filename = File.basename(arg)
		path = File.dirname(arg)
		rcsfile = File.join(path, 'RCS', filename) + SFX
		unless File.exists? rcsfile
			rcsfile.replace File.join(path, filename) + SFX
			unless File.exists? rcsfile
				not_found "RCS file for #{filename} in #{path}"
			end
		end
	end

	RCS.parse(filename, rcsfile, parse_options)
end

exit status
