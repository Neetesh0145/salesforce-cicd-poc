/**
 * Sample class used to prove the CI/CD pipeline end to end.
 * Change the message in a feature branch to see a delta validation and deployment.
 */
public with sharing class CiCdHealthCheck {
    public static String ping() {
        return 'CI/CD pipeline is alive v2';
    }
}
