#!/usr/bin/perl
# Self explained code by j0nix
# PREPARATIONS: yum install perl-Net-SNMP perl-WWW-Curl perl-JSON perl-Switch perl-String-Random
# /j0nix
use threads;
use strict;
use warnings;
use Net::SNMP;
use Time::HiRes;
use Getopt::Std;
use WWW::Curl::Easy;
use JSON;
use Switch;
use String::Random;
# First some basic stuff
my %opts;

my $random = new String::Random;

$0 =~ s{.*/}{}; 

getopts("f:o:w:c:h", \%opts);

my $num_args = $#ARGV + 1;

my $printFile = "/tmp/$0.result"; 	# Default output file

my $nb_process = 20; 				# Maximun nr of concurrent threads

my $waiting = 0.0005;				# Paus time, used in loop creating threads

#snmpcalls that are allowed
my @validsnmp=("get", "set", "table");

my ($snmpq,$snmpoid);

sub usage() {

	print "
	Usage: $0 -f filename [-o resultfile] [-m max concurrent threads] [-w wait time] <get|set|table> <oid|\"oid + set type & value\">

		-f 	File with ip or mac-addresses (or mixed), NOTE: One per line
		-o	Outputfile, default = $printFile
		-c	Max concurrent threads allowed running, default = $nb_process
		-w	Time to pause script before creating a new job, default $waiting 
			(Variable for preventing utilize of all cpu resources)


	Ex. 
		$0 -f macaddresses.txt get .1.3.6.1.2.1.1.4.0
		$0 -f macaddresses.txt -o resultFile.txt -w 0.05 -c 10 set \".1.3.6.1.2.1.1.4.0 s j0nixRulez\"\n\n

		SPECIAL FEATURE: 

		- Set randomized value if defined RANDOMIZE as value in your set string  

		$0 -f macaddresses.txt set \".1.3.6.1.2.1.1.4.0 s RANDOMIZE\"
		
		\n\n";
	exit 0;
}

if ("@validsnmp" =~ /\b$ARGV[0]\b/){
    $snmpq = shift(@ARGV);
}
else{
    &usage();
}
#get that oid
if ($ARGV[0]) {
	$snmpoid = shift(@ARGV);
} else {
    &usage();
}

if ($ARGV[0]) {
        my %topts;
	getopts("f:o:w:c:h", \%topts);
        @opts{keys %topts} = values %topts;
}
#        foreach (@ARGV) { print "$_\n"; }
use Data::Dumper;
print Dumper %opts;

if ($opts{h} || !$opts{f}) {
	&usage();
}

$printFile =  $opts{o} if $opts{o}; 		# if specified, set output file
$nb_process =  $opts{c} if $opts{c}; 		# if specified, set concurrent threads
$waiting =  $opts{w} if $opts{w}; 		# if specified, set paus time

#verify & set snmp query type to use

local $| = 1; 					# Perl magic, tells print to flush the buffer when called..

open(FILE, $opts{f}) or die("Unable to open file ".$opts{f});
	my @macaddresses = <FILE>;		# Read file input to an array
close(FILE);

# Variable hell...
my $total =  @macaddresses; 			# For presentation, Total macs in file

my $process = 1; 				# Counter for presentation, Processed macs

my $counter = 0; 				# For use to identify key in Threads array. 

my (@Threads,$mac,$thread); 			# some more useful variables...

my $now = time; 				# Well.. timestamp like right now...

my @running = (); 				# holds current threads in running state

@running = threads->list(); 			# Get current running threads... Like zero right now...

while (scalar @macaddresses > 0) { 		# In while loop we shift @macaddresses. This tells to stop when none is left... 

		if (scalar @running >= $nb_process) { #Have we reached maximum nr of concurrent threads?

			while (scalar @running == $nb_process) { # while we have max concurrent threads

				$counter = 0; # used i below foreach to identify array position

				foreach my $thr (@Threads) { # loop Threads array, placeholer for threads...

					if ($thr->is_joinable()) { # is thread  finished?

						&print_result($printFile,$thr->join); # print any output generated from thread
						splice(@Threads,$counter,1); # remove thread from Threads array
                                	}
					
					$counter++; # counting...
                        	}

				Time::HiRes::sleep(0.005); # Try prevent script to work to fast and eat all server resources

                        	@running = threads->list(); # how many threads are still active?
                	}
		}

		$mac = shift(@macaddresses); # Get a macaddress

		# Do that SNMP polling.. 
		$thread = threads->create( \&snmp_stuff,$mac); # create a thread and make it work, calling function snmp_stuff with variable mac
		
        	push (@Threads, $thread); # placehold thread in an array

		$counter = 0;  # our identifier for key position in array... again

		foreach my $thr (@Threads) { # this do the same as foreach above...

                	if ($thr->is_joinable()) {
				&print_result($printFile,$thr->join);
				splice(@Threads,$counter,1);
                	}

			$counter++;

			@running = threads->list();
       		}

		Time::HiRes::sleep($waiting); # Some waiting again to avoid utilization of server resources
		
		# Print progress
		printf "\r %s processed of %s | Concurrent %s  | debug: %s     ",$process,$total,scalar @running, scalar @Threads;
		
		$process++; # counting precessed macs

	}

	printf "\nAll done looping all those cm:s... now... we wait for script to get all results and finish up!\n";
	# how long did that take?
	my $exectime = time - $now;
	printf("\nTime consumed: %02d:%02d:%02d\n", int($exectime / 3600), int(($exectime % 3600) / 60), int($exectime % 60));

	# After we have now initiaded all macs in file we make shure we get all results... 
	
	while (scalar @running != 0) {

			foreach my $thr (@Threads) {
				if ($thr->is_joinable()) {
						&print_result($printFile,$thr->join);
				}
			}
			
			Time::HiRes::sleep(0.005);
			@running = threads->list();
			printf "\r %s threds are still running ...", scalar @running;

			# here we dont care about removing jobs from Threads placeholder...
	}

	print "\n\n ===> FINISHED <=== \n";

	# how long did this take?
	$exectime = time - $now;
	printf("\nTotal execution time: %02d:%02d:%02d\n\n", int($exectime / 3600), int(($exectime % 3600) / 60), int($exectime % 60));
	exit(0);

sub snmp_stuff
{
	#use Data::Dumper;
	#print Dumper $variable;
	chomp(my $m = shift); # my input variable

	my ($ip,$result,$retval);

	if ($m =~ m/(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/) { # this regexp also matches things like 099.888.77.6, but, fuck that, just interestning if its formated as an ip
		$ip = $m;
	} else {
		my $url = "here we craft an url calling an implementation of 'https://github.com/j0nix/j0nix-rest-api' to fetch ip for that macadress".$m;
		$ip = &ppAPI($url); # Calling function witch above link reference. A REST call too pp-api
		return "$m => OFFLINE" if ($ip !~ m/(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/); 
	}	

	# Start molding a snmpcall
	my ($session, $error) = Net::SNMP->session( -hostname  => $ip,-community => 'private',-version => 2, -timeout => 3,-retries => 0, );
		
	if (!defined $session) { # Did we fuck this up?
      		$retval = $error; # get that error message
		$session->close();

   	} else { # If all good to go

		switch ($snmpq) {

			case "set" {
				 my %snmptype = ( # Hash for convert to valid ASN 
                                        'a' => IPADDRESS,
                                        'c' => COUNTER32,
                                        'C' => COUNTER64,
                                        'g' => GAUGE32,
                                        'h' => OCTET_STRING,
                                        'x' => OCTET_STRING,
                                        'i' => INTEGER,
                                        'o' => OBJECT_IDENTIFIER,
                                        's' => OCTET_STRING,
                                );
				#INTEGER INTEGER32 OCTET_STRING OBJECT_IDENTIFIER IPADDRESS COUNTER COUNTER32 GAUGE GAUGE32 UNSIGNED32 TIMETICKS OPAQUE COUNTER64
				
				my ($oid,$type,$value) = split(/ /, $snmpoid); # split that setstring so we can craft a valid snmpset
				return "unknown type reference $type, change or update script" if (!$snmptype{$type}); # eather that coder is a fucko... or that user is

				if ($value eq "RANDOMIZE") { # Using special randomize feature?
					
					if ($type eq "i") { 
						$value = $random->randregex('\d\d\d\d\d\d\d\d\d'); # numeric value if type is integer
					} else {
						$value = $random->randpattern("...........");
					}
				}
				$result = $session->set_request( -varbindlist => [ $oid, $snmptype{$type}, $value ],); # go set shit
			}
			case "table" {

				my $r = $session->get_table(-baseoid => $snmpoid);

   				if (defined $r) { # did we get a result from our snmppoll?
					foreach (Net::SNMP::oid_lex_sort(keys(%{$r}))) {
						my $x = $_;
						$x =~ s/^($snmpoid)(.*)/$2/;
						
						$result->{$snmpoid} .= "\n\t".$x." = ".$r->{$_};
					}
				}

			}
			else {
                                $result = $session->get_request(-varbindlist => [ $snmpoid ],);
			}
		}
			
   		if (!defined $result) { # did we get a result from our snmppoll?
      			$retval = "ERROR: $m => ".$session->hostname().",".$session->error(); # Error message
      			$session->close();

   		} else {
			if ($snmpq eq 'set') {
				my ($oid,$type,$value) = split(/ /, $snmpoid);
				$retval = "$m, $snmpq $oid $type $value => ".$result->{$oid};
			}
			elsif ($snmpq eq 'table') {
				$retval = "$m, $snmpoid => ".$result->{$snmpoid};
			}
			else {
				$retval = "$m => ".$result->{$snmpoid};
			}
   			$session->close();
		}
	}

	return $retval; # report back result 
}

sub ppAPI {
	my $addr = shift; # Tha url
	# start building a curl call
	my $curl = WWW::Curl::Easy->new;
	my ($ip,$decoded); # declare some usefull variables...
	my $response_body = ''; # variable that we later on going to use for return
	open(my $fileb, ">", \$response_body); # Open pipe to variable
	$curl->setopt(CURLOPT_WRITEDATA,$fileb); # telling curl where to write its output
	$curl->setopt(CURLOPT_URL, $addr); # what url is curl calling
	my $retcode = $curl->perform; # make that curl call
	if ($retcode == 0) { # Did it all go as expected?
		$decoded = decode_json($response_body); # Since we get response in json we need to decode that..
		if (defined($decoded->{'IPADDRESS'})) { # Did we get back expected json data?
			$ip = $decoded->{'IPADDRESS'} # get ipaddress from that fancy json reply
		} else {
			$ip = $response_body; # return whatever that cool REST api replyed
		}
        } else { # Ohh no.. we got fucked
		$ip = print("\n\nError!?: $retcode ".$curl->strerror($retcode)." ".$curl->errbuf.",".$addr."\n"); # error message
	}
	return $ip; # return whatever produced in above code snippet...
}

sub print_result { # Just makes a print...
	my ($file,$message) = @_;
	open MSG,">>".$file or die "Can't open file $!";
		printf MSG "%s\n", $message;
	close MSG;
}
