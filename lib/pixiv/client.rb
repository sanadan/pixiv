module Pixiv
  class Client
    # A new agent
    # @return [Mechanize::HTTP::Agent]
    def self.new_agent
      agent = Mechanize.new
      agent.max_history = 1
      agent.pluggable_parser['image/gif'] = Mechanize::Download
      agent.pluggable_parser['image/jpeg'] = Mechanize::Download
      agent.pluggable_parser['image/png'] = Mechanize::Download
      agent
    end

    # @return [Mechanize::HTTP::Agent]
    attr_reader :agent
    # @return [Integer]
    attr_reader :member_id

    # A new instance of Client, logged in with the given credentials
    # @overload initialize(pixiv_id, password)
    #   @param [String] pixiv_id
    #   @param [String] password
    #   @yield [agent] (optional) gives a chance to customize the +agent+ before logging in
    # @overload initialize(agent)
    #   @param [Mechanize::HTTP::Agent] agent
    # @return [Pixiv::Client]
    def initialize(*args)
      if args.size < 2
        @agent = args.first || self.class.new_agent
        yield @agent if block_given?
        ensure_logged_in
      else
        pixiv_id, password = *args
        @agent = self.class.new_agent
        yield @agent if block_given?
        login(pixiv_id, password)
      end
    end

    # Log in to Pixiv
    # @param [String] pixiv_id
    # @param [String] password
    def login(pixiv_id, password)
      doc = agent.get("#{ROOT_URL}/index.php")
      return if doc && doc.body =~ /logout/
      form = doc.forms_with(action: '/login.php').first
      puts doc.body and raise Error::LoginFailed, 'login form is not available' unless form
      form.pixiv_id = pixiv_id
      form.pass = password
      doc = agent.submit(form)
      raise Error::LoginFailed unless doc && doc.body =~ /logout/
      @member_id = member_id_from_mypage(doc)
    end

    # @param [Integer] illust_id
    # @return [Pixiv::Illust] illust bound to +self+
    def illust(illust_id)
      attrs = {illust_id: illust_id}
      illust = Illust.lazy_new(attrs) { agent.get(Illust.url(illust_id)) }
      illust.bind(self)
    end

    # @param [Integer] member_id
    # @return [Pixiv::Member] member bound to +self+
    def member(member_id = member_id)
      attrs = {member_id: member_id}
      member = Member.lazy_new(attrs) { agent.get(Member.url(member_id)) }
      member.bind(self)
    end

    # @param [Pixiv::Member, Integer] member_or_member_id
    # @param [Integer] page_num
    def bookmark_list(member_or_member_id = member_id, page_num = 1)
      x = member_or_member_id
      member_id = x.is_a?(Member) ? x.member_id : x
      attrs = {member_id: member_id, page_num: page_num}
      BookmarkList.lazy_new(attrs) { agent.get(BookmarkList.url(member_id, page_num)) }
    end

    # @param [Pixiv::BookmarkList, Pixiv::Member, Integer] list_or_member
    # @param [Hash] opts
    # @option opts [Boolean] :include_deleted (false)
    #   whether the returning enumerator yields deleted illust as +nil+ or not
    # @return [Pixiv::PageCollection::Enumerator]
    def bookmarks(list_or_member, opts = {})
      list = list_or_member.is_a?(BookmarkList) ? list_or_member
                                                : bookmark_list(list_or_member)
      PageCollection::Enumerator.new(self, list, !!opts[:include_deleted])
    end

    # Downloads the image to +io_or_filename+
    # @param [Pixiv::Illust] illust
    # @param [#write, String, Array<String, Symbol, #call>] io_or_filename io or filename or pattern (see {#filename_from_pattern})
    # @param [Symbol] size image size (+:small+, +:medium+, or +:original+)
    def download_illust(illust, io_or_filename, size = :original)
      size = {:s => :small, :m => :medium, :o => :original}[size] || size
      url = illust.__send__("#{size}_image_url")
      referer = case size
                when :small then nil
                when :medium then illust.url
                when :original then illust.original_image_referer
                else raise ArgumentError, "unknown size `#{size}`"
                end
      save_to = io_or_filename
      if save_to.is_a?(Array)
        save_to = filename_from_pattern(save_to, illust, url)
      end
      FileUtils.mkdir_p(File.dirname(save_to)) unless save_to.respond_to?(:write)
      @agent.download(url, save_to, [], referer)
    end

    # Downloads the images to +pattern+
    # @param [Pixiv::Illust] illust the manga to download
    # @param [Array<String, Symbol, #call>] pattern pattern (see {#filename_from_pattern})
    # @note +illust#manga?+ must be +true+
    # @todo Document +&block+
    def download_manga(illust, pattern, &block)
      action = DownloadActionRegistry.new(&block)
      illust.original_image_urls.each_with_index do |url, n|
        begin
          action.before_each.call(url, n) if action.before_each
          filename = filename_from_pattern(pattern, illust, url)
          FileUtils.mkdir_p(File.dirname(filename))
          @agent.download(url, filename, [], illust.original_image_referer)
          action.after_each.call(url, n) if action.after_each
        rescue
          action.on_error ? action.on_error.call($!) : raise
        end
      end
    end

    protected

    def ensure_logged_in
      doc = agent.get("#{ROOT_URL}/mypage.php")
      raise Error::LoginFailed unless doc.body =~ /logout/
      @member_id = member_id_from_mypage(doc)
    end

    def member_id_from_mypage(doc)
      doc.at('.profile_area a')['href'].match(/(\d+)$/).to_a[1].to_i
    end

    # Generate filename from +pattern+ in context of +illust+ and +url+
    #
    # @param [Array<String, Symbol, #call>] pattern
    # @param [Pixiv::Illust] illust
    # @param [String] url
    # @return [String] filename
    #
    # The +pattern+ is an array of string, symbol, or object that responds to +#call+.
    # Each component of the +pattern+ is replaced by the following rules and then
    # the +pattern+ is concatenated as the returning +filename+.
    #
    # * +:image_name+ in the +pattern+ is replaced with the base name of the +url+
    # * Any other symbol is replaced with the value of +illust.__send__(the_symbol)+
    # * +#call+-able object is replaced with the value of +the_object.call(illust)+
    # * String is left as-is
    def filename_from_pattern(pattern, illust, url)
      pattern.map {|i|
        if i == :image_name
          name = File.basename(url)
          if name =~ /\.(\w+)\?\d+$/
            name += '.' + $1
          end
          name
        elsif i.is_a?(Symbol) then illust.__send__(i)
        elsif i.respond_to?(:call) then i.call(illust)
        else i
        end
      }.join('')
    end
  end

  # @private
  class DownloadActionRegistry
    def initialize(&block)
      instance_eval(&block) if block
    end

    def before_each(&block)
      block ? (@before_each = block) : @before_each
    end

    def after_each(&block)
      block ? (@after_each = block) : @after_each
    end

    def on_error(&block)
      block ? (@on_error = block) : @on_error
    end
  end
end
