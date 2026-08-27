# Review Questions - Lab 02
 
## 1. Public Subnet Without Internet Connectivity
 
Creating a subnet and naming it `public-subnet`, adding the tag `Tier=public`, and enabling auto-assign public IPv4 addresses do not actually make the subnet public. What is missing is a route table containing a default route (`0.0.0.0/0`) pointing to an Internet Gateway (IGW) attached to the VPC.
 
The name and tag are only labels used to identify and organize resources; they do not affect network routing. Similarly, having a public IPv4 address only gives an instance an address that can potentially be reached from the internet. Without a route through an Internet Gateway, there is no path for internet traffic to leave or enter the subnet.
 
## 2. Security Groups vs Network ACLs
 
Consider a USMS web request where a client connects to the web server on TCP port 80. The client sends traffic inbound to the web server on port 80, and the server sends the response outbound back to the client's temporary TCP port.
 
- A **Security Group** is stateful, so allowing inbound TCP 80 automatically allows the corresponding response traffic.
- With a **Network ACL**, which is stateless, both the inbound request and the outbound response must be permitted by separate rules.
When a new network-access requirement arrives, I would normally use a Security Group first because it provides stateful, instance-level access control and requires fewer rules for normal application communication. I would use a Network ACL when subnet-level filtering or an additional layer of network control is required.
 
## 3. Security Group Reference vs CIDR
 
Using `usms-app-sg` as the source for PostgreSQL access is more flexible than allowing a fixed CIDR such as `10.0.1.0/24`.
 
For example, the CIDR-based configuration would silently break if the application tier were moved to a different subnet with a different CIDR, because the database rule would still only allow the old address range. The group-referenced configuration would continue working because the instances would still belong to `usms-app-sg`.
 
A second example would be adding another application subnet in another Availability Zone with a different CIDR. The CIDR-based rule would need another rule for the new subnet, while the Security Group reference would automatically allow the new application instances as long as they use `usms-app-sg`.
 
This demonstrates why security-group references are useful for expressing the intended relationship between application and database tiers rather than depending on their current IP ranges.
 
## 4. NAT Gateway and Availability Zones
 
The NAT Gateway must be located in `usms-public-subnet-a` because it needs a route to the Internet Gateway in order to provide outbound internet access for resources in the private subnet. The private subnet cannot directly use the Internet Gateway for this purpose because it is designed to have no direct internet route. Instead, its default route points to the NAT Gateway.
 
If Availability Zone `a` becomes unavailable, the NAT Gateway in that AZ would also become unavailable. As a result, `usms-private-subnet-a` would lose its normal outbound internet path. More importantly, if `usms-private-subnet-b` also depends on the NAT Gateway in AZ `a`, it would lose outbound connectivity as well.
 
This shows that the real availability boundary is not simply the subnet; network dependencies such as NAT Gateways also need to be distributed across Availability Zones for high availability.
 
## 5. S3 Gateway Endpoint
 
With the S3 gateway endpoint, a request from an instance in a private USMS subnet to `usms-student-data` is routed through the VPC's S3 gateway endpoint. The traffic remains within the AWS network and does not need to travel through the NAT Gateway or the public internet.
 
Without the endpoint, the private instance would normally send the request through its NAT Gateway, which then provides the path toward S3. The traffic still uses AWS infrastructure, but it takes an unnecessary NAT-based path rather than using the dedicated VPC endpoint.
 
The endpoint therefore provides a more direct private path to S3 and can reduce NAT Gateway processing costs. It also reduces exposure because the S3 traffic does not need to use a public-internet route.
 
## 6. Restarting Floci and Looking Up the VPC by Tag
 
Looking up the VPC by its `Name` tag after restarting Floci proved that the VPC persisted independently of the previous shell session. If the existing `VPC_ID` shell variable had simply been reused, the test would only have shown that the variable still contained the old VPC ID. It would not have demonstrated that the VPC could be discovered again from the persisted Floci environment.
 
This relates to the persistence problem encountered in Lab 1 Step 14, where resources or state did not necessarily remain available as expected after restarting the environment. Re-discovering the VPC by tag therefore provided stronger evidence that the infrastructure itself persisted rather than relying on information stored only in the shell environment.
 
## 7. Verifying Security Groups When Floci Does Not Enforce Them
 
Even though Floci does not actually enforce Security Group traffic rules, the correctness of the configuration can still be verified by inspecting the Security Group objects and their rules. For example, the database Security Group can be checked to confirm that PostgreSQL on port 5432 allows traffic from `usms-app-sg` and does not unnecessarily allow access from arbitrary CIDR ranges.
 
The verification script could catch a mistake such as using the wrong source Security Group or opening PostgreSQL to the wrong CIDR, because the API configuration would not match the expected rule. However, it would not catch a mistake in the actual runtime behaviour of the firewall, such as whether a real packet would truly be blocked or allowed, because Floci does not enforce Security Group rules.
 
Therefore, the lab verifies the intended configuration, but not the complete real-world network enforcement behaviour.