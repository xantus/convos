package Convos::Connection;

=head1 NAME

Convos::Connection - Mojolicious controller for IRC connections

=cut

use Mojo::Base 'Mojolicious::Controller';

=head1 METHODS

=head2 add_connection

Add a new connection based on network name.

=cut

sub add_connection {
  my $self = shift->render_later;
  my $validation = $self->validation;
  my $name = $self->param('name') || '';

  $validation->input->{channels} = [$self->param('channels')];
  $validation->input->{login} = $self->session('login');

  Mojo::IOLoop->delay(
    sub {
      my($delay) = @_;
      $self->redis->hgetall("irc:network:$name", $delay->begin);
    },
    sub {
      my($delay, $params) = @_;

      $validation->input->{$_} ||= $params->{$_} for keys %$params;
      $self->app->core->add_connection($validation, $delay->begin);
    },
    sub {
      my($delay, $errors, $conn) = @_;

      if($errors and $self->param('wizard')) {
        $self->stash(template => 'connection/wizard')->wizard;
      }
      elsif($errors) {
        $self->settings;
      }
      else {
        $self->redirect_to($self->param('wizard') ? 'convos' : 'settings');
      }
    },
  );
}

=head2 add_network

Add a new network.

NOTE: This method currently also does update.

=cut

sub add_network {
  my $self = shift->render_later;
  my $validation = $self->validation;
  my @channels = $self->param('channels');
  my($is_default, $name, $redis, $referrer);

  $self->stash(body_class => 'tactile', channels => \@channels);
  $self->req->method eq 'POST' or return $self->render;

  $validation->input->{tls} ||= 0;
  $validation->input->{password} ||= 0;
  $validation->required('name')->like(qr{^[-a-z0-9]+$});
  $validation->required('server')->like(qr{^[-a-z0-9_\.]+(:\d+)?$});
  $validation->required('password')->in(0, 1);
  $validation->required('tls')->in(0, 1);
  $validation->optional('home_page')->like(qr{^https?://.});
  $validation->has_error and return $self->render(status => 400);
  $validation->output->{channels} = join ' ', $self->param('channels');

  if($validation->output->{server} =~ s!:(\d+)!!) {
    $validation->output->{port} = $1;
  }
  else {
    $validation->output->{port} = $validation->input->{tls} ? 6697 : 6667;
  }

  $redis = $self->redis;
  $name = delete $validation->output->{name};
  $is_default = $self->param('default') || 0;
  $referrer = $self->param('referrer') || '/';

  Mojo::IOLoop->delay(
    sub {
      my($delay) = @_;

      $redis->set("irc:default:network", $name, $delay->begin) if $is_default;
      $redis->sadd("irc:networks", $name, $delay->begin);
      $redis->hmset("irc:network:$name", $validation->output, $delay->begin);
    },
    sub {
      my($delay, @success) = @_;
      $self->redirect_to($referrer);
    },
  );
}

=head2 edit_network

Used to edit settings for a network.

=cut

sub edit_network {
  my $self = shift->render_later;
  my $name = $self->stash('name');

  $self->stash(body_class => 'tactile');

  if($self->req->method eq 'POST') {
    $self->param(referrer => $self->req->url->to_abs);
    $self->validation->input->{name} = $name;
    $self->add_network;
    return;
  }

  Mojo::IOLoop->delay(
    sub {
      my($delay) = @_;

      $self->redis->execute(
        [ get => 'irc:default:network' ],
        [ hgetall => "irc:network:$name" ],
        $delay->begin
      );
    },
    sub {
      my($delay, $default_network, $network) = @_;

      $network->{server} or return $self->render_not_found;
      $self->param($_ => $network->{$_} || '') for qw( password tls home_page );
      $self->param(name => $name);
      $self->param(default => 1) if $default_network eq $name;
      $self->param(server => join ':', @$network{qw( server port )});
      $self->render(
        channels => [ split /\s+/, $network->{channels} || '' ],
        default_network => $default_network,
        name => $name,
        network => $network,
      );
    },
  );
}

=head2 wizard

Used to add the first connection.

=cut

sub wizard {
  my $self = shift->render_later;
  my $redis = $self->redis;

  Mojo::IOLoop->delay(
    sub {
      my($delay) = @_;

      $self->stash(body_class => 'tactile');
      $redis->smembers('irc:networks', $delay->begin);
    },
    sub {
      my $delay = shift;
      my @names = sort @{ shift || [] };

      @names = ('loopback') unless @names;
      $delay->begin(0)->(\@names);
      $redis->get('irc:default:network', $delay->begin);
      $redis->hgetall("irc:network:$_", $delay->begin) for @names;
    },
    sub {
      my($delay, $names, $default_network, @networks) = @_;
      my @channels;

      for my $network (@networks) {
        $network->{name} = shift @$names;
        @channels = split /\s+/, $network->{channels} || '' if $network->{name} eq $default_network;
      }

      $self->render(
        channels => \@channels,
        default_network => $default_network,
        networks => \@networks,
      );
    },
  );
}

=head1 COPYRIGHT

See L<Convos>.

=head1 AUTHOR

Jan Henning Thorsen

Marcus Ramberg

=cut

1;