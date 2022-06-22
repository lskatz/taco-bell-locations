#!/usr/bin/env perl 

use warnings;
use strict;
use Data::Dumper;
use Getopt::Long;
use File::Basename qw/basename/;
use WWW::Crawler::Mojo;
use HTML::StripTags qw/strip_tags/;
use threads;
use Thread::Queue;

local $0 = basename $0;
sub logmsg{local $0=basename $0; print STDERR "$0: @_\n";}
exit(main());

sub main{
  my $settings={};
  GetOptions($settings,qw(help debug numcpus=i)) or die $!;
  usage() if($$settings{help});
  $$settings{baseurl} ||= "https://locations.tacobell.com";
  $$settings{numcpus} ||= 1;

  printLocations($$settings{baseurl}, $settings);

  return 0;
}

sub printLocations{
  my($baseurl, $settings) = @_;

  my %seen_url;

  # Initialize threads
  my @thr;
  my $urlQueue = Thread::Queue->new;
  my $printQueue = Thread::Queue->new;
  for(my $i=0;$i<$$settings{numcpus};$i++){
    $thr[$i] = threads->new(\&findZips, $urlQueue, $printQueue, $settings);
  }
  my $printer = threads->new(\&printer, $printQueue, $settings);

  my $bot = WWW::Crawler::Mojo->new;
  $bot->on(res => sub{
      my($bot, $scrape, $job, $res) = @_;
      for my $child_job($scrape->()){
        # Only look at depth <= 2 for crawling and parsing
        next if($child_job->depth > 2);
        my $url = $child_job->{_url};

        # Only look at .htm or .html
        next if($url !~ /\.html?/);

        # make an increment a hash value but only after it has been tested in the if
        next if($seen_url{$url}++);
        $bot->enqueue($child_job);

        if($$settings{debug} && scalar(keys(%seen_url)) > 100){
          logmsg "DEBUG";
          return;
        }
        
        # Get the URL and parse it for 5 digit numbers
        # by sending this URL to the threads
        # but do not parse if it's on the main URL with depth < 2
        next if($child_job->depth < 2);
        $urlQueue->enqueue($url);
      }
    }
  );
  $bot->enqueue($baseurl);
  $bot->crawl;

  # Send term signal to threads
  for(@thr){
    $urlQueue->enqueue(undef);
  }
  # Join the threads
  for(@thr){
    $_->join;
  }
  # Now that the threads have been joined, send a termination signal to the printer
  $printQueue->enqueue(undef);
  $printer->join;

  # Return a true
  return 1;
}

sub findZips{
  my($Q, $printQ, $settings) = @_;

  my @buffer = ();

  my $i=0;
  while(defined(my $url = $Q->dequeue)){
    $i++;
    my $content = `wget '$url' -O - 2>/dev/null`;
    # Remove all html tags from the content to help remove false positives
    my $stripped = strip_tags($content);
    logmsg $url." ".substr($stripped,0, 10)."...";
    # zip code regex: two letter code then whitespace then 5 digits
    while($stripped=~/[A-Z]{2}\s+(\d{5})\b/g){
      # Print tab separated URL and 5 digit number
      push(@buffer, join("\t", $url, $1));
    }

    if($i % 1000 == 0){
      $printQ->enqueue(@buffer);
      @buffer = ();
    }
  }
  $printQ->enqueue(@buffer);

  return $i;
}

sub printer{
  my($Q, $settings) = @_;
  while(defined(my $line = $Q->dequeue)){
      print $line."\n";
  }
}

sub usage{
  print "$0: makes a spreadsheet of all taco bell locations
  Usage: $0 
  --numcpus 1
  --debug       Stop after 100 URLs
  --help        This useful help menu
  ";
  exit 0;
}
