require 'spec_helper'

describe Devise::Strategies::OpenidAuthenticatable do
  include Rspec::Rails::RequestExampleGroup

  def openid_params
    {
      "openid.identity"=>identity,
      "openid.sig"=>"OWYQspA5zZhoqRFhfSMFX/hLkok=",
      "openid.return_to"=>"http://www.example.com/users/sign_in?_method=post",
      "openid.op_endpoint"=>"http://openid.example.org",
      "openid.mode"=>"id_res",
      "openid.response_nonce"=>"2010-01-11T00:00:00Zeru5O3ETpTNX0A",
      "openid.ns"=>"http://specs.openid.net/auth/2.0",
      "openid.ns.ext1"=>"http://openid.net/srv/ax/1.0",
      "openid.ext1.value.ext0"=>"dimitrij@example.com",
      "openid.ext1.type.ext0"=>"http://axschema.org/contact/email",
      "openid.assoc_handle"=>"AOQobUeSdDcZUnQEYna4AZeTREaJiCDoii26u_x7wdrRrU5TqkGaqq9N",
      "openid.claimed_id"=>identity,
      "openid.signed"=>"op_endpoint,claimed_id,identity,return_to,response_nonce,assoc_handle,ns.ext1,ext1.mode,ext1.type.ext0,ext1.value.ext0"
    }
  end

  def stub_completion
    ax_info  = mock('AXInfo', :data => { "http://axschema.org/contact/email" => ["dimitrij@example.com"] })
    OpenID::AX::FetchResponse.stubs(:from_success_response).returns(ax_info)

    endpoint = mock('EndPoint')
    endpoint.stubs(:claimed_id).returns(identity)
    success  = OpenID::Consumer::SuccessResponse.new(endpoint, OpenID::Message.new, "ANY")
    OpenID::Consumer.any_instance.stubs(:complete_id_res).returns(success)
  end

  def identity
    @identity || 'http://openid.example.org/myid'
  end

  before do
    User.create! do |u|
      u.identity_url = "http://openid.example.org/myid"
    end
  end

  after do
    User.delete_all
  end

  describe "GET /protected/resource" do
    before { get '/' }

    it 'should redirect to sign-in' do
      response.should be_redirect
      response.should redirect_to('/users/sign_in')
    end
  end

  describe "GET /users/sign_in" do
    before { get '/users/sign_in' }

    it 'should render the page' do
      response.should be_success
      response.should render_template("sessions/new")
    end
  end

  describe "POST /users/sign_in (without a identity URL param)" do
    before { post '/users/sign_in' }

    it 'should render the sign-in form' do
      response.should be_success
      response.should render_template("sessions/new")
    end
  end

  describe "POST /users/sign_in (with an empty identity URL param)" do
    before { post '/users/sign_in', 'user' => { 'identity_url' => '' } }

    it 'should render the sign-in form' do
      response.should be_success
      response.should render_template("sessions/new")
    end
  end

  describe "POST /users/sign_in (with a valid identity URL param)" do
    before do
      Rack::OpenID.any_instance.stubs(:begin_authentication).returns([302, {'location' => 'http://openid.example.org/server'}, ''])
      post '/users/sign_in', 'user' => { 'identity_url' => 'http://openid.example.org/myid' }
    end

    it 'should forward request to provider' do
      response.should be_redirect
      response.should redirect_to('http://openid.example.org/server')
    end
  end
  
  describe "POST /users/sign_in (with rememberable)" do
    before do
      post '/users/sign_in', 'user' => { 'identity_url' => 'http://openid.example.org/myid', 'remember_me' => 1 }
    end
    
    it 'should forward request to provider, with params preserved' do
      response.should be_redirect
      redirect_uri = URI.parse(response.header['Location'])
      redirect_uri.host.should == "openid.example.org"
      redirect_uri.path.should match(/^\/server/)
      
      # Crack open the redirect URI and extract the return parameter from it, then parse it too
      req = Rack::Request.new(Rack::MockRequest.env_for(redirect_uri.to_s))
      return_req = Rack::Request.new(Rack::MockRequest.env_for(req.params['openid.return_to']))
      return_req.params['user']['remember_me'].to_i.should == 1
    end
  end

  describe "POST /users/sign_in (from OpenID provider, with failure)" do

    before do
      post '/users/sign_in', "openid.mode"=>"failure", "openid.ns"=>"http://specs.openid.net/auth/2.0", "_method"=>"post"
    end

    it 'should fail authentication with failure' do
      response.should be_success
      response.should render_template("sessions/new")
      flash[:alert].should match(/failed/i)
    end
  end

  describe "POST /users/sign_in (from OpenID provider, when cancelled failure)" do

    before do
      post '/users/sign_in', "openid.mode"=>"cancel", "openid.ns"=>"http://specs.openid.net/auth/2.0", "_method"=>"post"
    end

    it 'should fail authentication with failure' do
      response.should be_success
      response.should render_template("sessions/new")
      flash[:alert].should match(/cancelled/i)
    end
  end

  describe "POST /users/sign_in (from OpenID provider, success, user already present)" do

    before do
      stub_completion
      post '/users/sign_in', openid_params.merge("_method"=>"post")
    end

    it 'should accept authentication with success' do
      response.should be_redirect
      response.should redirect_to('http://www.example.com/')
      flash[:notice].should match(/success/i)
    end

    it 'should update user-records with retrieved information' do
      User.should have(1).record
      User.first.email.should == 'dimitrij@example.com'
    end
  end
  
  describe "POST /users/sign_in (from OpenID provider, success, rememberable)" do

    before do
      stub_completion
      post '/users/sign_in', openid_params.merge("_method"=>"post", "user" => { "remember_me" => 1 })
    end

    it 'should accept authentication with success' do
      response.should be_redirect
      response.should redirect_to('http://www.example.com/')
      flash[:notice].should match(/success/i)
    end

    it 'should update user-records with retrieved information and remember token' do
      User.should have(1).record
      User.first.email.should == 'dimitrij@example.com'
      User.first.remember_token.should_not be_nil
    end
  end

  describe "POST /users/sign_in (from OpenID provider, success, new user)" do

    before do
      @identity = 'http://openid.example.org/newid'
      stub_completion
      post '/users/sign_in', openid_params.merge("_method"=>"post")
    end

    it 'should accept authentication with success' do
      response.should be_redirect
      response.should redirect_to('http://www.example.com/')
      flash[:notice].should match(/success/i)
    end

    it 'should auto-create user-records (if supported)' do
      User.should have(2).records
    end

    it 'should update new user-records with retrieved information' do
      User.order(:id).last.email.should == 'dimitrij@example.com'
    end
  end

end
