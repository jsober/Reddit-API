package Reddit::API;

use strict;
use warnings;
use Carp;

use File::Spec     qw//;
use LWP::UserAgent qw//;
use HTTP::Request  qw//;
use URI::Encode    qw/uri_encode/;
use JSON           qw//;

require Reddit::API::Account;
require Reddit::API::Link;

#===============================================================================
# Constants
#===============================================================================

use constant DEFAULT_LIMIT      => 25;

use constant VIEW_HOT           => '/';
use constant VIEW_NEW           => '/new';
use constant VIEW_CONTROVERSIAL => '/controversial';
use constant VIEW_TOP           => '/top';
use constant VIEW_DEFAULT       => VIEW_HOT;

use constant VOTE_UP            => 1;
use constant VOTE_DOWN          => -1;
use constant VOTE_NONE          => 0;

#===============================================================================
# Parameters
#===============================================================================

our $BASE_URL = 'http://www.reddit.com';
our $UA       = 'Reddit::API/0.1';

#===============================================================================
# Package routines
#===============================================================================

sub build_query {
    my $param = shift;
    join '&', map {uri_encode($_) . '=' . uri_encode($param->{$_})} keys %$param;
}

sub subreddit {
    my $subject = shift;
    $subject =~ s/^\/r//; # trim leading /r
    $subject =~ s/^\///;  # trim leading slashes
    $subject =~ s/\/$//;  # trim trailing slashes

    if ($subject !~ /\//) {   # no slashes in name - it's probably good
        if ($subject eq '') { # front page
            return '';
        } else {              # subreddit
	        return $subject;
        }
    } else { # fail
        return;
    }
}

#===============================================================================
# Class methods
#===============================================================================

use fields (
    'modhash', # store session modhash
    'cookie',  # store user cookie
);

sub new {
    my ($class, %param) = @_;
    my $session = $param{from_session_file};
    my $self    = fields::new($class);
    $self->load_session($session) if $session;
    return $self;
}

#===============================================================================
# Internal management
#===============================================================================

sub request {
    my ($self, $method, $path, $query, $post_data) = @_;
    $method = uc $method;
    $path   =~ s/^\///; # trim off leading slash

    my $request = HTTP::Request->new();
    my $url     = sprintf('%s/%s', $BASE_URL, $path);

    $url = sprintf('%s?%s', $url, build_query($query))
        if defined $query;

    $request->header('Cookie', sprintf('reddit_session=%s', $self->{cookie}))
        if $self->{cookie};

    if ($method eq 'POST') {
        $post_data = {} unless defined $post_data;
        $post_data->{modhash} = $self->{modhash} if $self->{modhash};
        $post_data->{uh}      = $self->{modhash} if $self->{modhash};

        $request->uri($url);
        $request->method('POST');
        $request->content_type('application/x-www-form-urlencoded');
        $request->content(build_query($post_data));
    } else {
        $request->uri($url);
        $request->method('GET');
    }

    my $ua  = LWP::UserAgent->new(agent => $UA, env_proxy => 1);
    my $res = $ua->request($request);

    if ($res->is_success) {
        return $res->content;
    } else {
        croak sprintf('Request error: %s', $res->status_line);
    }
}

sub json_request {
    my ($self, $method, $path, $query, $post_data) = @_;
    $query     ||= {};
    $post_data ||= {};

    $post_data->{api_type} = 'json';
    $path .= '.json' if $method eq 'GET';

    my $response = $self->request($method, $path, $query, $post_data);
    my $json = JSON::from_json($response);

    if (ref $json eq 'HASH' && $json->{json}) {
        my $result = $json->{json};
        if (@{$result->{errors}}) {
            my @errors = map {$_->[1]} @{$result->{errors}};
            croak sprintf("Error(s): %s", join('|', @errors));
        } else {
            return $result;
        }
    } else {
        return $json;
    }
}

sub is_logged_in {
    return defined $_[0]->{modhash};
}

sub require_login {
    my $self = shift;
    croak 'You must be logged in to perform this action'
        unless $self->is_logged_in;
}

sub save_session {
    my ($self, $file) = @_;
    if ($self->{modhash}) {
        my $session = { modhash => $self->{modhash}, cookie => $self->{cookie} };
	    my $file_path = File::Spec->catfile($file);
        open(my $fh, '>', $file_path) or croak $!;
        print $fh JSON::to_json($session);
        close $fh;
        return 1;
    } else {
        return 0;
    }
}

sub load_session {
    my ($self, $file) = @_;
    my $file_path = File::Spec->catfile($file);
    if (-f $file_path) {
        open(my $fh, '<', $file_path) or croak $!;
        my $data = do { local $/; <$fh> };
        close $fh;

        my $session = JSON::from_json($data);
        $self->{modhash} = $session->{modhash};
        $self->{cookie} = $session->{cookie};

        return 1;
    } else {
        return 0;
    }
}

#===============================================================================
# User and account management
#===============================================================================

sub login {
    my ($self, $usr, $pwd) = @_;
    !$usr && croak 'Username expected';
    !$pwd && croak 'Password expected';

    my $result = $self->json_request('POST', sprintf('/api/login/%s/', $usr), undef, { user => $usr, passwd => $pwd });
    my @errors = @{$result->{errors}};

    if (@errors) {
        my $message = join(' | ', map { join(', ', @$_) } @errors);
        croak sprintf('Login errors: %s', $message);
    } else {
        $self->{modhash} = $result->{data}{modhash};
        $self->{cookie}  = $result->{data}{cookie};
    }
}

sub me {
    my $self = shift;
    $self->require_login;
    if ($self->is_logged_in) {
	    my $result = $self->json_request('GET', '/api/me/');
	    return Reddit::API::Account->new($self, $result->{data});
    }
}

sub mine {
    my $self = shift;
    $self->require_login;
    if ($self->is_logged_in) {
        my $result = $self->json_request('GET', '/reddits/mine/');
        return {
            map { 
                $_->{data}{display_name} => Reddit::API::SubReddit->new($self, $_->{data})
            } @{$result->{data}{children}}
        };
    }
}

#===============================================================================
# Other miscellaneous utilites
#===============================================================================

sub find_subreddits {
    my ($self, $query) = @_;
    my $result = $self->json_request('GET', '/reddits/search/', { q => $query });
    my %subreddits = map {$_->{data}{display_name} => $_->{data}{url}} @{$result->{data}{children}};
    return \%subreddits;
}

sub fetch_links {
    my ($self, %param) = @_;
    my $subreddit = $param{subreddit} || '';
    my $view      = $param{view}      || Reddit::API::VIEW_DEFAULT();
    my $limit     = $param{limit}     || Reddit::API::DEFAULT_LIMIT();
    my $before    = $param{before};
    my $after     = $param{after};
    
    # Get subreddit and path
    $subreddit = subreddit($subreddit);
    my $path = $subreddit
        ? sprintf('/r/%s/%s', $subreddit, $view)
        : sprintf('/%s', $view);

    my @args = ('GET', $path);
    if ($before || $after || $limit) {
	    my %query;
	    $query{limit}  = $limit  if defined $limit;
	    $query{before} = $before if defined $before;
	    $query{after}  = $after  if defined $after;
	    push @args, \%query;
    }

    my $result = $self->json_request(@args);
    return {
        before => $result->{data}{before},
        after  => $result->{data}{after},
        items  => [ map {Reddit::API::Link->new($self, $_->{data})} @{$result->{data}{children}} ],
    };
}

sub submit_link {
    my ($self, %param) = @_;
    my $subreddit = $param{subreddit} || '';
    my $title     = $param{title}     || croak 'Expected "title"';
    my $url       = $param{url}       || croak 'Expected "url"';
    
    $subreddit = subreddit($subreddit);
    $self->require_login;

    my $result = $self->json_request('POST', '/api/submit/', undef, {
        title => $title,
        url   => $url,
        sr    => $subreddit,
        kind  => 'link',
    });
    
    return $result->{data}{id};
}

sub submit_text {
    my ($self, %param) = @_;
    my $subreddit = $param{subreddit} || '';
    my $title     = $param{title}     || croak 'Expected "title"';
    my $text      = $param{text}      || croak 'Expected "text"';
    
    $subreddit = subreddit($subreddit);
    $self->require_login;

    my $result = $self->json_request('POST', '/api/submit/', undef, {
        title => $title,
        text  => $text,
        sr    => $subreddit,
        kind  => 'self',
    });
    
    return $result->{data}{id};
}


1;